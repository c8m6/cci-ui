# frozen_string_literal: true

require "test_helper"
require "yaml"

class ZabbixTemplateTest < ActiveSupport::TestCase
  setup do
    @export = YAML.safe_load_file(Rails.root.join("integrations/zabbix/cci-certificates.yaml")).fetch("zabbix_export")
    @template = @export.fetch("templates").first
    @discovery = @template.fetch("discovery_rules").first
  end

  test "7.4 template uses unique UUIDv4 identifiers and item keys" do
    assert_equal "7.4", @export.fetch("version")
    uuids = collect_values(@export, "uuid")
    assert_equal uuids.uniq, uuids
    uuids.each { |uuid| assert_match(/\A[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}\z/, uuid) }
    items = @template.fetch("items") + [@discovery] + @discovery.fetch("item_prototypes")
    keys = items.map { |item| item.fetch("key") }
    assert_equal keys.uniq, keys
    items.select { |item| item["type"] == "DEPENDENT" }.each do |item|
      assert_equal "cci.certificates.raw", item.fetch("master_item").fetch("key")
    end
  end

  test "HTTP request protects token transport and checks response before discovery" do
    master = @template.fetch("items").first
    assert_equal "HTTP_AGENT", master.fetch("type")
    assert_equal "{$CCI.URL}/integrations/zabbix", master.fetch("url")
    assert_equal "NO", master.fetch("follow_redirects")
    assert_equal "YES", master.fetch("verify_peer")
    assert_equal "YES", master.fetch("verify_host")
    assert_equal "200", master.fetch("status_codes")
    assert_equal "JAVASCRIPT", master.fetch("preprocessing").first.fetch("type")
    token = @template.fetch("macros").find { |entry| entry.fetch("macro") == "{$CCI.ZABBIX.TOKEN}" }
    assert_equal "SECRET_TEXT", token.fetch("type")
    assert_empty token.fetch("value", "")
    references = @export.to_json.scan(/\{\$[A-Z.]+\}/).uniq
    assert_empty references - @template.fetch("macros").map { |entry| entry.fetch("macro") }
  end

  test "discovery retains lost resources and selects the appropriate renewal policy" do
    assert_equal "30d", @discovery.fetch("lifetime")
    assert_equal "DELETE_AFTER", @discovery.fetch("lifetime_type")
    assert_equal "1d", @discovery.fetch("enabled_lifetime")
    assert_equal "DISABLE_AFTER", @discovery.fetch("enabled_lifetime_type")
    assert_equal(%w[{#CERTID} {#CERTCN} {#ISSUER} {#RENEWAL}],
      @discovery.fetch("lld_macro_paths").map { |entry| entry.fetch("lld_macro") })
    triggers = @discovery.fetch("trigger_prototypes")
    assert_equal 5, triggers.length
    triggers.each { |trigger| assert_equal "NO_DISCOVER", trigger.fetch("discover") }
    %w[manual puppet].each do |renewal|
      overrides = @discovery.fetch("overrides").select do |override|
        Regexp.new(override.fetch("filter").fetch("conditions").first.fetch("value")).match?(renewal)
      end
      assert_equal 1, overrides.length
      pattern = Regexp.new(overrides.first.fetch("operations").first.fetch("value"))
      selected = triggers.select { |trigger| pattern.match?(trigger.fetch("name")) }
      expected = renewal == "manual" ? %w[WARNING HIGH] : %w[INFO WARNING HIGH]
      assert_equal(expected, selected.map { |trigger| trigger.fetch("priority") })
    end
  end

  test "expiration problems require fresh data before generating recovery events" do
    @discovery.fetch("trigger_prototypes").each do |trigger|
      assert_equal "RECOVERY_EXPRESSION", trigger.fetch("recovery_mode")
      assert_equal "nodata(/CCI Certificates/cci.certificates.raw,2h)=0", trigger.fetch("recovery_expression")
      assert_includes trigger.fetch("expression"), "nodata(/CCI Certificates/cci.certificates.raw,2h)=0"
    end
  end

  test "actual template expressions implement inclusive Puppet boundaries without overlapping alerts" do
    { 8 => nil, 7 => "INFO", 4 => "INFO", 3 => "WARNING", 2 => "WARNING",
      1 => "HIGH", 0.5 => "HIGH", 0 => "HIGH", -1 => "HIGH" }.each do |days, severity|
      assert_equal Array(severity), priorities("AUTO:", days), "Puppet at #{days} days"
    end
    assert_equal [], priorities("AUTO:", 7 + (1.0 / 86_400))
    assert_equal ["INFO"], priorities("AUTO:", 3 + (1.0 / 86_400))
    assert_equal ["WARNING"], priorities("AUTO:", 1 + (1.0 / 86_400))
    { 61 => [], 45 => ["WARNING"], 20 => ["HIGH"], 14 => ["HIGH"], 5 => ["HIGH"],
      -1 => ["HIGH"] }.each { |days, expected| assert_equal expected, priorities("MANUAL:", days) }
    refute_includes collect_values(@export, "priority"), "DISASTER"
  end

  private

  # Evaluate comparisons from the shipped expressions rather than a second policy.
  def priorities(prefix, days)
    macros = @template.fetch("macros").to_h { |entry| [entry.fetch("macro"), entry["value"]] }
    selected = @discovery.fetch("trigger_prototypes").select do |trigger|
      next false unless trigger.fetch("name").start_with?(prefix)

      expression = trigger.fetch("expression").gsub(%r{last\(/CCI Certificates/cci.cert.valid_until\[\{#CERTID\}\]\)-now\(\)},
        (days * 86_400).to_s).gsub("nodata(/CCI Certificates/cci.certificates.raw,2h)", "0")
      expression = expression.gsub(/\{\$[A-Z.]+\}/) { |macro| (Integer(macros.fetch(macro).delete_suffix("d")) * 86_400).to_s }
      expression.split(" and ").all? do |comparison|
        match = /\A(-?[0-9.]+)(<=|>=|<|>|=)(-?[0-9.]+)\z/.match(comparison)
        assert match, "Unrecognized expression: #{comparison}"
        Float(match[1]).public_send(match[2] == "=" ? "==" : match[2], Float(match[3]))
      end
    end
    selected.map { |trigger| trigger.fetch("priority") }
  end

  def collect_values(value, key)
    case value
    when Hash
      value.flat_map { |name, child| name == key ? [child] : collect_values(child, key) }
    when Array
      value.flat_map { |child| collect_values(child, key) }
    else
      []
    end
  end
end
