# frozen_string_literal: true

require "test_helper"

class CertificateInteroperabilityTest < ActiveSupport::TestCase
  test "native OpenSSL imports and exports preserve keys chains and Unicode passwords" do
    root, root_key = issue(name: "Root", ca: true)
    certificate, key = issue(issuer: root, issuer_key: root_key)
    password = "pässword-long"
    entry = { certificate: certificate, key: key, chain: [root] }

    exported = Certificates::Pkcs12.dump([entry], password: password)
    native = OpenSSL::PKCS12.new(exported, password)
    assert_equal certificate.to_der, native.certificate.to_der
    assert certificate.check_private_key(native.key)
    assert_equal [root.to_der], native.ca_certs.map(&:to_der)

    %w[AES-256-CBC PBE-SHA1-3DES].each do |algorithm|
      imported = OpenSSL::PKCS12.create(password, "native", key, certificate, [root], algorithm, algorithm).to_der
      parsed = Certificates::Pkcs12.load(imported, password: password)
      assert_equal [certificate, root].map(&:to_der).sort, parsed.certificates.map(&:to_der).sort
      assert_equal 1, parsed.keys.size
      assert certificate.check_private_key(parsed.keys.first)
      assert_raises(Certificates::Error) { Certificates::Pkcs12.load(imported, password: "wrong") }
    end
  end

  test "multi-key PKCS12 rejects tampered MACs and excessive derivation work" do
    first, key = issue
    second, other = issue(name: "second.test", serial: 2)
    entries = [{ certificate: first, key: key, chain: [] }, { certificate: second, key: other, chain: [] }]
    encoded = Certificates::Pkcs12.dump(entries, password: "long-password")
    parsed = Certificates::Pkcs12.load(encoded, password: "long-password")
    assert_equal 2, parsed.keys.size
    assert first.check_private_key(parsed.keys.first)
    assert second.check_private_key(parsed.keys.last)

    pfx = OpenSSL::ASN1.decode(encoded)
    mac = pfx.value[2].value[0].value[1]
    mac.value = mac.value.dup.tap { |bytes| bytes.setbyte(0, bytes.getbyte(0) ^ 1) }
    assert_raises(Certificates::Error) { Certificates::Pkcs12.load(pfx.to_der, password: "long-password") }

    pfx = OpenSSL::ASN1.decode(encoded)
    pfx.value[2].value[2] = OpenSSL::ASN1::Integer(1_000_001)
    assert_raises(Certificates::Error) { Certificates::Pkcs12.load(pfx.to_der, password: "long-password") }
  end

  test "Vault reads existing version-one envelopes with an explicit standalone area key" do
    secret = OpenSSL::Random.random_bytes(32)
    encoded = Base64.strict_encode64(secret)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = secret
    iv = cipher.random_iv
    cipher.auth_data = "cci:external:server/1"
    encrypted = cipher.update("private test material") + cipher.final
    envelope = JSON.generate(version: 1, iv: Base64.strict_encode64(iv),
      tag: Base64.strict_encode64(cipher.auth_tag), data: Base64.strict_encode64(encrypted))

    assert_equal "private test material", Certificates::Vault.decrypt(envelope,
      area: "external", id: "server/1", encryption_key: encoded)
    assert_raises(Certificates::Error) do
      Certificates::Vault.decrypt(envelope, area: "external", id: "server/2", encryption_key: encoded)
    end
    assert_raises(Certificates::Error) do
      Certificates::Vault.decrypt(envelope, area: "other", id: "server/1", encryption_key: encoded)
    end
    assert_raises(Certificates::Error) do
      Certificates::Vault.decrypt(envelope, area: "external", id: "server/1",
        encryption_key: Base64.strict_encode64(OpenSSL::Random.random_bytes(32)))
    end
    assert_raises(ArgumentError) do
      Certificates::Vault.encrypt("private test material", area: "external", id: "server/1",
        encryption_key: Base64.strict_encode64("short"))
    end
  end

  test "writer envelopes remain readable through Vault and the packaged standalone client" do
    certificate, key = issue
    record = store(certificate, key: key)
    path = "#{ConsulStore.prefix(record.area)}/keys/#{record.source_id}"
    envelope = ConsulStore.client.get(path).fetch(:value)
    assert_equal key.private_to_pem, Certificates::Vault.decrypt(envelope, area: record.area, id: record.source_id)

    %w[cci_client.rb cci_writer.rb consul_connection.rb area_secrets.rb area_configuration.rb
      certificates/vault.rb certificates/error.rb].each do |file|
      assert_equal File.binread(Rails.root.join("lib", file)),
        File.binread(Rails.root.join("integrations/puppet/cci/lib", file)), "Stale Puppet copy: #{file}"
    end
  end
end
