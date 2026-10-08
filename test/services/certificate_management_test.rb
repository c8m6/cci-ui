# frozen_string_literal: true

require "test_helper"
require_relative "../support/puppet_acme_fixture"

class CertificateManagementTest < ActiveSupport::TestCase
  include PuppetAcmeFixture

  test "optional metadata accepts current and older module summaries without projecting unknown fields" do
    record = publish_puppet_acme(cert: issue.first)
    metadata = acme_metadata(record)
    metadata["acme_renewal"]["unrelated_secret"] = "never-display"
    summary = CertificateManagement.renewal_summary(metadata)
    assert_equal %w[domains key_size key_type not_after version], summary.keys.sort
    assert_instance_of Time, summary.fetch("not_after")
    assert_equal 1, summary.fetch("version")
    metadata["acme_renewal"].delete("version")
    metadata["acme_renewal"].delete("issuers")
    assert CertificateManagement.renewal_summary(metadata)
    assert_equal "never-display", metadata["acme_renewal"]["unrelated_secret"]
  end

  test "malformed extensions do not break details or falsely show a validated management summary" do
    [nil, false, "invalid", [], {}, { "not_after" => 42 },
      { "not_after" => "invalid", "domains" => ["a.test"], "key_type" => "rsa", "key_size" => 2048 },
      { "not_after" => "2027-01-01T00:00:00Z", "domains" => [nil], "key_type" => "ec", "key_size" => 256 },
      { "not_after" => "2027-01-01T00:00:00Z", "domains" => ["a.test"], "key_type" => "rsa", "key_size" => 2048,
        "version" => "1" }].each do |extension|
      metadata = { "acme_renewal" => extension }
      assert CertificateManagement.automated?(metadata), "presence still warrants a manual-operation warning"
      assert_nil CertificateManagement.renewal_summary(metadata)
    end
    [nil, {}].each do |metadata|
      refute CertificateManagement.automated?(metadata)
      assert_nil CertificateManagement.renewal_summary(metadata)
    end
  end

  test "module envelope decrypts in CCI and CCI envelope decrypts with module parameters" do
    cert, key = issue
    record = publish_puppet_acme(cert: cert, key: key)
    assert_equal key.public_to_der, CertificateMaterial.load(record, private_key: true).fetch(:key).public_to_der
    envelope = puppet_envelope(key.private_to_pem, "automated")
    assert_equal key.private_to_pem,
      Certificates::Vault.decrypt(JSON.generate(envelope), area: "zone_a", id: "automated/1")
    # The test namespace is randomized and not "cci", while AAD remains fixed.
    refute_equal "cci", ConsulStore.namespace
    %w[automated/2 other/1].each do |id|
      assert_raises(Certificates::Error) { Certificates::Vault.decrypt(JSON.generate(envelope), area: "zone_a", id: id) }
    end
    assert_raises(Certificates::Error) { Certificates::Vault.decrypt(JSON.generate(envelope), area: "zone_b", id: "automated/1") }
    generated = JSON.parse(Certificates::Vault.encrypt(key.private_to_pem, area: "zone_a", id: "automated/1"))
    assert_equal %w[data iv tag version], generated.keys.sort
    assert_equal 1, generated.fetch("version")
    assert_equal 12, Base64.strict_decode64(generated.fetch("iv")).bytesize
    assert_equal 16, Base64.strict_decode64(generated.fetch("tag")).bytesize
    cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
    cipher.key = Base64.strict_decode64(ENV.fetch("ZONE_A_KEY"))
    cipher.iv = Base64.strict_decode64(generated.fetch("iv"))
    cipher.auth_tag = Base64.strict_decode64(generated.fetch("tag"))
    cipher.auth_data = "cci:zone_a:automated/1"
    assert_equal key.private_to_pem, cipher.update(Base64.strict_decode64(generated.fetch("data"))) + cipher.final
  end
end
