require "test_helper"
require "open3"
require_relative "../../examples/add_certificate"

class AreaSecretsTest < ActiveSupport::TestCase
  test "JSON keys take precedence with per-area environment fallback" do
    assert_equal "mapped", AreaSecrets.fetch("zone_a", "CCI_AREA_KEYS" => '{"zone_a":"mapped"}', "ZONE_A_KEY" => "old")
    assert_equal "old", AreaSecrets.fetch("zone_b", "CCI_AREA_KEYS" => '{"zone_a":"mapped"}', "ZONE_B_KEY" => "old")
    assert_equal "old", AreaSecrets.fetch("zone_a", "CCI_AREA_KEYS" => "", "ZONE_A_KEY" => "old")
    assert_equal "", AreaSecrets.fetch("zone_a", {})
    ["invalid-secret-json", "null", "[]", '{"zone_a":123}', '{"../zone":"secret"}'].each do |raw|
      error = assert_raises(ArgumentError) { AreaSecrets.fetch("zone_a", "CCI_AREA_KEYS" => raw) }
      assert_not_includes error.message, raw
    end
  end

  test "UI and external writers share keys supplied only through the JSON environment map" do
    previous = ENV["CCI_AREA_KEYS"]
    ENV["CCI_AREA_KEYS"] = JSON.generate("zone_a" => Base64.strict_encode64("m" * 32))
    cert, key = issue
    id = CertificateExample.add(area: "zone_a", lookup: "mapped-secret", cert: cert, key: key,
      client: "external", actor: "test")
    CatalogIndexer.refresh_consul
    record = Certificate.find_by!(source_id: id)
    assert CertificateMaterial.load(record, private_key: true)[:certificate].check_private_key(key)
    encrypted = Certificates::Vault.encrypt("secret material", area: "zone_a", id: "test")
    assert_equal "secret material", Certificates::Vault.decrypt(encrypted, area: "zone_a", id: "test")
  ensure
    ENV["CCI_AREA_KEYS"] = previous
  end

  test "setup helper emits shell-safe configuration without creating a file" do
    label = "Example's $HOME `false`"
    env = { "CCI_AREAS" => JSON.generate("custom" => label), "CCI_LEGACY_PATHS" => "{}" }
    before = File.exist?(Rails.root.join(".env")) ? File.binread(Rails.root.join(".env")) : nil
    output, error, result = Open3.capture3(env, "ruby", Rails.root.join("bin/setup-local").to_s, "--stdout")
    assert result.success?, error
    # Evaluate only shell assignments generated from synthetic data in this test.
    command = output + "\n" + %q{ruby -rjson -e 'puts JSON.generate(ENV.to_h.slice("CCI_AREAS", "CCI_LEGACY_PATHS", "CCI_AREA_KEYS"))'}
    parsed, error, result = Open3.capture3("bash", "-c", command)
    assert result.success?, error
    settings = JSON.parse(parsed)
    assert_equal({ "custom" => label }, JSON.parse(settings.fetch("CCI_AREAS")))
    assert_equal({}, JSON.parse(settings.fetch("CCI_LEGACY_PATHS")))
    assert_equal 32, Base64.strict_decode64(JSON.parse(settings.fetch("CCI_AREA_KEYS")).fetch("custom")).bytesize
    assert_equal before, File.exist?(Rails.root.join(".env")) ? File.binread(Rails.root.join(".env")) : nil
  end
end
