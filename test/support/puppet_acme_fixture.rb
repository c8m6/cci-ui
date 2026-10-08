# frozen_string_literal: true

# Synthetic documents matching zaeh/zaeh-acme_kvstore main at 2a5bf5c.
# No upstream runtime dependency: these exercise the public storage contract.
module PuppetAcmeFixture
  def publish_puppet_acme(cert:, key: nil, certid: "automated", renewal: true)
    meta = { "active_version" => 1, "latest_version" => 1, "status" => "active",
             "updated_at" => "2026-10-01T10:00:00.000000Z", "client" => "puppet",
             "updated_by" => "puppet:worker.example.test" }
    if renewal
      meta["acme_renewal"] = { "version" => 1, "not_after" => cert.not_after.utc.iso8601,
                               "domains" => ["www.example.test"], "key_type" => "rsa", "key_size" => 2048,
                               "issuers" => ["test-ca_2030-01-01"] }
    end
    public_doc = { "pem" => cert.to_pem, "tags" => [], "has_key" => !key.nil?,
                   "created_at" => meta.fetch("updated_at"), "client" => "puppet",
                   "created_by" => meta.fetch("updated_by") }
    base = ConsulStore.prefix("zone_a")
    writes = [ConsulConnection.set("#{base}/certids/#{certid}", meta, index: 0),
      ConsulConnection.set("#{base}/certs/#{certid}/1", public_doc, index: 0)]
    writes << ConsulConnection.set("#{base}/keys/#{certid}/1", puppet_envelope(key.private_to_pem, certid), index: 0) if key
    ConsulStore.client.transaction(writes)
    CatalogIndexer.refresh_consul
    Certificate.find_by!(area: "zone_a", certid: certid, certificate_version: 1)
  end

  # Independent envelope producer using the module's documented byte lengths and AAD.
  def puppet_envelope(pem, certid)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = Base64.strict_decode64(ENV.fetch("ZONE_A_KEY"))
    iv = OpenSSL::Random.random_bytes(12)
    cipher.iv = iv
    cipher.auth_data = "cci:zone_a:#{certid}/1"
    ciphertext = cipher.update(pem) + cipher.final
    { "version" => 1, "iv" => Base64.strict_encode64(iv), "tag" => Base64.strict_encode64(cipher.auth_tag(16)),
      "data" => Base64.strict_encode64(ciphertext) }
  end

  def acme_metadata(record)
    JSON.parse(ConsulStore.status_snapshot(record).fetch(:value))
  end
end
