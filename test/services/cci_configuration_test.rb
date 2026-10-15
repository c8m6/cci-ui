# frozen_string_literal: true

require "test_helper"
require "open3"

class CciConfigurationTest < ActiveSupport::TestCase
  def document
    YAML.safe_load_file(Rails.root.join("test/config.yml"))
  end

  def load_document(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, YAML.dump(data))
      return CciConfiguration.load_file(path, production: false)
    end
  end

  test "YAML snapshot validates defaults and is deeply immutable" do
    config = load_document(document)
    assert_equal 10, config.dig("certificates", "expiry_warning_days")
    assert_equal 60, config.dig("indexer", "interval_seconds")
    assert_equal "RSA", config.dig("csr", "defaults", "key_algorithm")
    assert config.fetch("areas").frozen?
    assert config.fetch("areas").fetch("zone_a").frozen?
    assert_raises(FrozenError) { config.fetch("server")["port"] = 1 }
  end

  test "missing required fields invalid keys types references and limits reject startup" do
    invalid = [
      document.except("version"), document.except("areas"), document.merge("version" => 2),
      document.merge("area_mode" => "multiple"), document.merge("areas" => {}),
      document.deep_merge("server" => { "port" => "3000" }),
      document.deep_merge("server" => { "allowed_hosts" => [] }),
      document.deep_merge("database" => { "password" => nil }),
      document.deep_merge("authentication" => { "oidc" => { "role_map" => { "group" => "missing_reader" } } }),
      document.deep_merge("areas" => { "../other" => { "name" => "Other", "encryption_key" => "secret" } }),
      document.deep_merge("areas" => { "zone_a" => { "filesystem" => { "legacy_path" => "relative" } } }),
      document.deep_merge("areas" => { "zone_a" => { "consul" => { "token" => "with whitespace" } } }),
      document.deep_merge("areas" => { "zone_a" => { "encryption_key" => "private-secret-invalid" } }),
      document.deep_merge("certificates" => { "expiry_warning_days" => 0 }),
      document.deep_merge("certificates" => { "reconciliation" => { "missing_after_scans" => 1 } }),
      document.deep_merge("certificates" => { "reconciliation" => { "max_delete_percent" => 101 } }),
      document.deep_merge("puppetdb" => { "enabled" => "true" }),
      document.deep_merge("puppetdb" => { "enabled" => true }),
      document.deep_merge("integrations" => { "zabbix" => { "certificate_sources" => "invalid" } }),
      document.deep_merge("csr" => { "defaults" => { "key_algorithm" => "EC", "key_size" => 4096 } })
    ]
    invalid.each do |data|
      error = assert_raises(CciConfiguration::Error) { load_document(data) }
      assert_not_includes error.message, "private-secret-invalid"
    end
  end

  test "safe YAML rejects duplicate keys aliases object tags and syntax errors without source content" do
    ["version: 1\nversion: 1\n", "--- !ruby/object:Object {}", "one: &a {}\ntwo: *a", "secret: [private-sensitive"].each do |text|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, text)
        error = assert_raises(CciConfiguration::Error) { CciConfiguration.load_file(path) }
        assert_not_includes error.full_message, "private-sensitive"
      end
    end
  end

  test "mixed direct and file secrets retain exact encryption bytes and redact log output" do
    Dir.mktmpdir do |dir|
      key_path = File.join(dir, "key")
      key = Base64.strict_encode64("r" * 32)
      File.write(key_path, "#{key}\n")
      data = document.deep_merge("consul" => { "token" => "direct-token" },
        "areas" => { "zone_a" => { "encryption_key" => { "file" => key_path } } })
      config = load_document(data)
      assert_equal key, config.dig("areas", "zone_a", "encryption_key")
      encrypted = Certificates::Vault.encrypt("existing material", area: "zone_a", id: "retained/1")
      CciConfiguration.instance_variable_set(:@current, config)
      assert_equal "existing material", Certificates::Vault.decrypt(encrypted, area: "zone_a", id: "retained/1")
      output = ContainerLogFormatter.new.call("ERROR", Time.current, "test", "direct-token #{key}")
      assert_not_includes output, "direct-token"
      assert_not_includes output, key
      File.delete(key_path)
      assert_raises(CciConfiguration::Error) { load_document(data) }
    end
  end

  test "Consul inheritance keeps independent URL prefix CA and credentials per area" do
    data = document.deep_merge("consul" => { "url" => "https://default.example.test", "prefix" => "shared", "token" => "global" },
      "areas" => { "zone_a" => { "consul" => { "token" => "area-a" } },
                   "zone_b" => { "consul" => { "url" => "https://other.example.test", "prefix" => "other", "token" => "area-b" } } })
    config = load_document(data)
    assert_equal "https://default.example.test", config.consul("zone_a").fetch("url")
    assert_equal "shared", config.consul("zone_a").fetch("prefix")
    assert_equal "area-a", config.consul("zone_a").fetch("token")
    assert_equal "https://other.example.test", config.consul("zone_b").fetch("url")
    assert_equal "other", config.consul("zone_b").fetch("prefix")
    assert_equal "area-b", config.consul("zone_b").fetch("token")
  end

  test "TLS file overrides and explicit anonymous tokens do not inherit a credential" do
    Dir.mktmpdir do |dir|
      ca = File.join(dir, "ca.pem")
      File.write(ca, "synthetic CA contents for path validation")
      data = document.deep_merge("consul" => { "ca_file" => ca, "token" => "global-token" },
        "areas" => { "zone_b" => { "consul" => { "ca_file" => "", "token" => "" } } })
      config = load_document(data)
      assert_equal ca, config.consul("zone_a").fetch("ca_file")
      assert_equal "", config.consul("zone_b").fetch("ca_file")
      assert_equal "", config.consul("zone_b").fetch("token")
      File.delete(ca)
      assert_raises(CciConfiguration::Error) { load_document(data) }
    end
  end

  test "invalid URL parser causes never expose configured content" do
    data = document.deep_merge("consul" => { "url" => "https://private-sensitive value" })
    error = assert_raises(CciConfiguration::Error) { load_document(data) }
    assert_not_includes error.full_message, "private-sensitive"
  end

  test "production refuses local authentication and missing explicit server and OIDC settings" do
    assert_raises(CciConfiguration::Error) { CciConfiguration.new(document, production: true) }
    data = document.deep_merge("authentication" => { "mode" => "oidc" })
    assert_raises(CciConfiguration::Error) { CciConfiguration.new(data, production: true) }
  end

  test "a current snapshot stays fixed when the bootstrap path changes" do
    previous = ENV.fetch("CCI_CONFIG_FILE", nil)
    config = CciConfiguration.current
    ENV["CCI_CONFIG_FILE"] = "/missing/config.yml"
    assert_same config, CciConfiguration.current
  ensure
    ENV["CCI_CONFIG_FILE"] = previous
  end

  test "setup helper outputs YAML without changing existing local configuration" do
    path = Rails.root.join("config.yml")
    before = File.binread(path) if File.file?(path)
    output, error, result = Open3.capture3("ruby", Rails.root.join("bin/setup-local").to_s, "--stdout")
    assert result.success?, error
    config = load_document(YAML.safe_load(output))
    assert_equal 32, Base64.strict_decode64(config.dig("areas", "zone_a", "encryption_key")).bytesize
    assert_equal 32, Base64.strict_decode64(config.dig("areas", "zone_b", "encryption_key")).bytesize
    assert_equal before, File.binread(path) if before
    assert_not File.exist?(path) unless before
  end
end
