# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["CCI_CONFIG_FILE"] ||= File.expand_path("config.yml", __dir__)
require "securerandom"
require "tmpdir"
require "fileutils"
require "json"
TEST_LEGACY_ROOT = Dir.mktmpdir("cci-test-legacy-")
require_relative "../lib/cci_configuration"
CciConfiguration.current
TEST_CONFIGURATION = Marshal.load(Marshal.dump(CciConfiguration.current))
TEST_CONFIGURATION.fetch("areas").fetch("zone_a")["filesystem"] = { "legacy_path" => TEST_LEGACY_ROOT }
TEST_CONFIGURATION.fetch("consul")["prefix"] = "cci-test/#{SecureRandom.hex(8)}"
CciConfiguration.instance_variable_set(:@current, Marshal.load(Marshal.dump(TEST_CONFIGURATION)))
require_relative "../config/environment"
require "rails/test_help"
ActiveRecord::Migration.maintain_test_schema!

module CertificateFixtures
  def settings = CciConfiguration.current.instance_variable_get(:@data)

  def configure_legacy_paths(paths)
    settings.fetch("areas").each do |id, area|
      area.delete("filesystem")
      area["filesystem"] = { "legacy_path" => paths.fetch(id) } if paths.key?(id)
    end
  end

  def puppetdb_settings(values)
    result = Marshal.load(Marshal.dump(TEST_CONFIGURATION.fetch("puppetdb")))
    values.each do |path, value|
      keys = path.split(".")
      target = keys[0...-1].inject(result) { |node, key| node[key] ||= {} }
      target[keys.last] = value
    end
    result
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
    cert.not_after = expired ? Time.now - 3600 : Time.now + (90 * 86_400)
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer || cert
    cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:#{name},IP:192.0.2.7"))
    cert.sign(issuer_key || key, OpenSSL::Digest.new("SHA256"))
    [cert, key]
  end

  def clear_consul
    prefix = ConsulStore.namespace
    raise "Unsafe test prefix" unless prefix.start_with?("cci-test/")

    ConsulStore.client.request("delete", "#{ConsulStore.client.path("#{prefix}/")}?recurse")
  end

  def store(cert, key: nil, area: "zone_a", certid: "test", chain: [], client: "test-client")
    chain.each do |issuer|
      name = Certificates::Codec.fingerprint(issuer)
      store(issuer, area: area, certid: name) unless Certificate.exists?(area: area, fingerprint: name)
    end
    id = ConsulStore.save(area: area, cert: cert, key: key, tags: ["Produktion"], certid: certid, actor: "test",
      client: client)
    CatalogIndexer.new.consul
    Certificate.find_by!(area: area, source_id: id)
  end
end

module ActiveSupport
  class TestCase
    include CertificateFixtures

    setup do
      CciConfiguration.instance_variable_set(:@current, Marshal.load(Marshal.dump(TEST_CONFIGURATION)))
      clear_consul
    end
  end
end

Minitest.after_run do
  FileUtils.remove_entry(TEST_LEGACY_ROOT)
  connection = ConsulStore.client
  connection.request("delete", "#{connection.path("#{ConsulStore.namespace}/")}?recurse")
end
