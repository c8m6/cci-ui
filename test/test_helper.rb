ENV["RAILS_ENV"] = "test"
ENV["AUTH_MODE"] = "local"
require "securerandom"
require "tmpdir"
require "fileutils"
require "json"
TEST_LEGACY_ROOT = Dir.mktmpdir("cci-test-legacy-")
ENV["CCI_AREAS"] = JSON.generate("zone_a" => "Zone A", "zone_b" => "Zone B")
ENV["CCI_LEGACY_PATHS"] = JSON.generate("zone_a" => TEST_LEGACY_ROOT)
ENV["CCI_AREA_KEYS"] = "{}"
ENV["PUPPETDB_ENABLED"] = "false"
ENV["PUPPETDB_FINGERPRINT_ALGORITHM"] = "sha256"
ENV["CONSUL_PREFIX"] = "cci-test/#{SecureRandom.hex(8)}"
require_relative "../config/environment"
require "rails/test_help"
ActiveRecord::Migration.maintain_test_schema!

module CertificateFixtures
  def configure_legacy_paths(paths)
    AreaConfiguration.instance_variable_set(:@configuration,
      AreaConfiguration.load_env("CCI_AREAS" => JSON.generate(AreaConfiguration.configuration.fetch("areas")),
        "CCI_LEGACY_PATHS" => JSON.generate(paths)))
  end

  def issue(name: "portal.example.test", issuer: nil, issuer_key: nil, serial: 1, ca: false, expired: false)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}/O=Test")
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 86_400
    cert.not_after = expired ? Time.now - 3600 : Time.now + 90 * 86_400
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer || cert
    cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:#{name},IP:192.0.2.7"))
    cert.sign(issuer_key || key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end

  def clear_consul
    prefix = ConsulStore.namespace
    raise "Unsafe test prefix" unless prefix.start_with?("cci-test/")
    ConsulStore.client.request("delete", ConsulStore.client.path(prefix + "/") + "?recurse")
  end

  def store(cert, key: nil, area: "zone_a", lookup: "test", chain: [], client: "test-client")
    id = ConsulStore.save(area: area, cert: cert, key: key, chain: chain, tags: ["Produktion"], lookup: lookup, actor: "test", client: client)
    CatalogIndexer.new.consul
    Certificate.find_by!(area: area, source_id: id)
  end
end

class ActiveSupport::TestCase
  include CertificateFixtures
  setup do
    ENV["ZONE_A_KEY"] = Base64.strict_encode64("r" * 32)
    ENV["ZONE_B_KEY"] = Base64.strict_encode64("s" * 32)
    clear_consul
  end
end

Minitest.after_run do
  FileUtils.remove_entry(TEST_LEGACY_ROOT)
  connection = ConsulStore.client
  connection.request("delete", connection.path(ConsulStore.namespace + "/") + "?recurse")
end
