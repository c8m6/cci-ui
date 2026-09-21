require "test_helper"

class CertificatesTest < ActiveSupport::TestCase
  test "PEM bundle and encrypted keys parse without losing entries" do
    root, root_key = issue(name: "Root", ca: true)
    leaf, key = issue(issuer: root, issuer_key: root_key)
    pem = leaf.to_pem + root.to_pem + key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "password")
    result = Certificates::Codec.parse(pem, password: "password")
    assert_equal 2, result.certificates.size
    assert leaf.check_private_key(result.keys.first)
    assert_equal [root.to_der], Certificates::Codec.chain(leaf, result.certificates).map(&:to_der)
    assert_raises(Certificates::Error) { Certificates::Codec.parse(pem, password: "wrong") }
  end

  test "JKS handles multiple keys trust certificates integrity and wrong passwords" do
    first, key = issue
    second, other = issue(name: "other.test", serial: 2)
    jks = Certificates::Jks.dump([{ certificate: first, key: key, chain: [] }, { certificate: second, key: other, chain: [] }, { certificate: second, key: nil, chain: [] }], password: "pässword-long")
    parsed = Certificates::Codec.parse(jks, password: "pässword-long")
    assert_equal 2, parsed.certificates.size
    assert_equal 2, parsed.keys.size
    assert first.check_private_key(parsed.keys.first)
    assert second.check_private_key(parsed.keys.last)
    assert_raises(Certificates::Error) { Certificates::Codec.parse(jks, password: "wrong") }
    jks.setbyte(30, jks.getbyte(30) ^ 1)
    assert_raises(Certificates::Error) { Certificates::Codec.parse(jks, password: "pässword-long") }
  end

  test "vault binds ciphertext to area and version" do
    encrypted = Certificates::Vault.encrypt("private", area: "zone_a", id: "one")
    assert_equal "private", Certificates::Vault.decrypt(encrypted, area: "zone_a", id: "one")
    assert_raises(Certificates::Error) { Certificates::Vault.decrypt(encrypted, area: "zone_b", id: "one") }
    assert_raises(Certificates::Error) { Certificates::Vault.decrypt(encrypted, area: "zone_a", id: "two") }
  end

  test "renewal preserves versions and encrypted keys" do
    cert, key = issue
    original = store(cert, key: key)
    renewed, renewed_key = issue(serial: 2)
    newer = store(renewed, key: renewed_key)
    assert_not original.reload.active
    assert newer.active
    raw = ConsulStore.client.get("#{ConsulStore.prefix('zone_a')}/private_keys/#{original.source_id}")[:value]
    assert_not_includes raw, "PRIVATE KEY"
    assert CertificateMaterial.load(original, private_key: true)[:certificate].check_private_key(key)
    assert_equal 3, store(cert, key: key).certificate_version
    ConsulStore.activate("zone_a", original.source_id, actor: "test")
    CatalogIndexer.new.consul
    assert original.reload.active
    assert_not_respond_to ConsulStore, :delete
  end

  test "search combines SAN tags and terms and respects area" do
    first, = issue
    hidden, = issue(name: "hidden.zone_b.test")
    store(first)
    store(hidden, area: "zone_b")
    visible = Certificate.visible_to(Identity.new(name: "reader", roles: ["zone_a_reader"]))
    assert_equal 1, CertificateSearch.call(visible, { q: "192.0.2.7 Produktion" }).count
    assert_equal 0, CertificateSearch.call(visible, { q: "portal impossible" }).count
    assert_equal 0, CertificateSearch.call(visible, { q: "hidden" }).count
    fingerprint = Certificates::Codec.fingerprint(first).scan(/../).join(":")
    assert_equal 1, CertificateSearch.call(visible, { q: fingerprint }).count
  end

  test "writer without key role exports only certificates from mixed PEM" do
    cert, key = issue
    Dir.mktmpdir do |dir|
      previous = AreaConfiguration.configuration
      configure_legacy_paths("zone_a" => dir)
      File.write(File.join(dir, "mixed.pem"), cert.to_pem + key.private_to_pem)
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      reader = Identity.new(name: "writer", roles: ["zone_a_writer"])
      content, = CertificateExport.call([record], identity: reader, format: "pem", include_key: false, include_chain: false, password: "")
      assert_includes content, "BEGIN CERTIFICATE"
      assert_not_includes content, "PRIVATE KEY"
      assert_raises(Certificates::Error) { CertificateExport.call([record], identity: reader, format: "pem", include_key: true, include_chain: false, password: "long-password") }
      File.write(File.join(dir, "mixed.pem"), issue(serial: 9).first.to_pem)
      assert_raises(Certificates::Error) { CertificateMaterial.load(record) }
    ensure
      AreaConfiguration.instance_variable_set(:@configuration, previous)
    end
  end

  test "PFX and DER export round trip" do
    cert, key = issue
    record = store(cert, key: key)
    writer = Identity.new(name: "writer", roles: ["zone_a_writer", "zone_a_key_exporter"])
    data, = CertificateExport.call([record], identity: writer, format: "p12", include_key: true, include_chain: false, password: "long-password")
    parsed = Certificates::Codec.parse(data, password: "long-password")
    assert_equal cert.to_der, parsed.certificates.first.to_der
    assert cert.check_private_key(parsed.keys.first)
    der, = CertificateExport.call([record], identity: writer, format: "der", include_key: false, include_chain: false, password: "")
    assert_equal cert.to_der, der
  end

  test "legacy paths cannot escape configured directory through symlinks" do
    Dir.mktmpdir do |dir|
      previous = AreaConfiguration.configuration
      configure_legacy_paths("zone_a" => dir)
      File.symlink("/etc/passwd", File.join(dir, "escape.pem"))
      assert_raises(Certificates::Error) { LegacyStore.safe_path("escape.pem") }
      assert_raises(Certificates::Error) { LegacyStore.safe_path("../../etc/passwd") }
    ensure
      AreaConfiguration.instance_variable_set(:@configuration, previous)
    end
  end

  test "key export requires both writer and separate key exporter role" do
    cert, key = issue
    record = store(cert, key: key)
    [%w[zone_a_reader], %w[zone_a_key_exporter], %w[zone_a_reader zone_a_key_exporter], %w[zone_a_writer]].each do |roles|
      identity = Identity.new(name: "test", roles: roles)
      assert_raises(Certificates::Error) { CertificateExport.call([record], identity: identity, format: "pem", include_key: true, include_chain: false, password: "long-password") }
    end
    identity = Identity.new(name: "keys", roles: %w[zone_a_writer zone_a_key_exporter])
    data, = CertificateExport.call([record], identity: identity, format: "pem", include_key: true, include_chain: false, password: "long-password")
    assert_includes data, "BEGIN ENCRYPTED PRIVATE KEY"
    assert cert.check_private_key(Certificates::Codec.parse(data, password: "long-password").keys.first)
  end

  test "PKCS12 preserves multiple keys and public only trust stores" do
    first, key = issue
    second, other = issue(name: "second.test", serial: 2)
    entries = [{ certificate: first, key: key, chain: [] }, { certificate: second, key: other, chain: [] }]
    data = Certificates::Pkcs12.dump(entries, password: "long-password")
    parsed = Certificates::Codec.parse(data, password: "long-password")
    assert_equal 2, parsed.keys.size
    assert_equal 2, parsed.certificates.size
    assert first.check_private_key(parsed.keys.first)
    trust = Certificates::Pkcs12.dump([{ certificate: first, key: nil, chain: [second] }], password: "long-password")
    parsed_trust = Certificates::Codec.parse(trust, password: "long-password")
    assert_empty parsed_trust.keys
    assert_equal 2, parsed_trust.certificates.size
    assert_raises(Certificates::Error) { Certificates::Codec.parse(data, password: "wrong") }
  end

  test "Consul CAS conflict leaves all writes unapplied" do
    connection = ConsulStore.client
    path = "#{ConsulStore.namespace}/conflict"
    connection.transaction([ConsulConnection.set(path, "first", index: 0)])
    assert_raises(ConsulConnection::Conflict) do
      connection.transaction([ConsulConnection.set(path, "wrong", index: 0), ConsulConnection.set(path + "-side", "unwanted")])
    end
    assert_equal "first", connection.get(path)[:value]
    assert_nil connection.get(path + "-side")
  end

  test "Puppet client pins version within compile and returns stable content" do
    cert, key = issue
    original = store(cert, key: key)
    client = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace, keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    pem = client.fetch(area: "zone_a", certid: "test")
    assert_equal cert.to_pem, pem
    renewed, new_key = issue(serial: 99)
    store(renewed, key: new_key)
    assert_equal pem, client.fetch(area: "zone_a", certid: "test")
    assert cert.check_private_key(OpenSSL::PKey.read(client.fetch(area: "zone_a", certid: "test", field: "private_key")))
    next_compile = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace)
    assert_equal renewed.to_pem, next_compile.fetch(area: "zone_a", certid: "test")
    assert_equal original.fingerprint, client.fetch(area: "zone_a", certid: "test", field: "metadata")["fingerprint"]
  end
end
