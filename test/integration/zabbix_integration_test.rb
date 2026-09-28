# frozen_string_literal: true

require "test_helper"

class ZabbixIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @saved_environment = ENV.to_h.slice("CCI_ZABBIX_INTEGRATION_ENABLED", "CCI_ZABBIX_INTEGRATION_TOKEN", "AUTH_MODE")
    ENV["CCI_ZABBIX_INTEGRATION_ENABLED"] = "true"
    ENV["CCI_ZABBIX_INTEGRATION_TOKEN"] = "synthetic-monitoring-token-for-tests"
    ENV["AUTH_MODE"] = "oidc"
  end

  teardown do
    %w[CCI_ZABBIX_INTEGRATION_ENABLED CCI_ZABBIX_INTEGRATION_TOKEN AUTH_MODE].each do |name|
      ENV[name] = @saved_environment[name]
    end
  end

  test "disabled or missing token configuration never exposes inventory" do
    [nil, "false", "invalid", "1"].each do |flag|
      ENV["CCI_ZABBIX_INTEGRATION_ENABLED"] = flag
      get "/integrations/zabbix", headers: authorization
      assert_response :not_found
      assert_empty response.body
    end
    ENV["CCI_ZABBIX_INTEGRATION_ENABLED"] = "true"
    [nil, "", " "].each do |token|
      ENV["CCI_ZABBIX_INTEGRATION_TOKEN"] = token
      get "/integrations/zabbix"
      assert_response :not_found
    end
  end

  test "only a well formed header bearer token authenticates" do
    [nil, "Bearer", "Basic abc", "Bearer incorrect", "Bearer x", "Bearer #{"x" * 200}",
      "Bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")},other",
      "Bearer  #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")}",
      "Bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")} extra"].each do |header|
      get "/integrations/zabbix", headers: { "Authorization" => header }.compact
      assert_response :unauthorized
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
      assert_empty response.body
      assert_nil response.headers["Set-Cookie"]
    end
    get "/integrations/zabbix", params: { token: ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN") }
    assert_response :unauthorized
    get "/integrations/zabbix", headers: { "Authorization" => "bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")}" }
    assert_response :success
  end

  test "snapshot has exact public fields and stable ids with duplicate common names" do
    cert, key = issue
    manual = store(cert, key: key, certid: "manual", client: "cci-ui")
    acme = store(cert, certid: "acme", client: "puppet-acme")
    puppet = store(cert, certid: "puppet", client: "puppet")
    acme.update!(created_by: "ACME-renewer")
    travel_to Time.zone.local(2026, 9, 28, 12) do
      get "/integrations/zabbix", headers: authorization
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_nil response.headers["Set-Cookie"]
      body = response.parsed_body
      assert_equal %w[certificates generated_at version], body.keys.sort
      assert_equal 1, body.fetch("version")
      assert_equal Time.current.to_i, body.fetch("generated_at")
      assert_equal([manual.id, acme.id, puppet.id], body.fetch("certificates").map { |entry| entry.fetch("id") })
      assert_equal(%w[manual acme puppet], body.fetch("certificates").map { |entry| entry.fetch("renewal") })
      assert_equal({ "id" => manual.id, "common_name" => manual.common_name, "issuer" => manual.issuer,
        "serial_number" => manual.serial, "valid_from" => cert.not_before.to_i, "valid_until" => cert.not_after.to_i,
        "renewal" => "manual" }, body.fetch("certificates").first)
      refute_includes response.body, key.private_to_pem
      refute_includes response.body, ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")
      refute_match(/private|password|secret|pem|csr|created_by|client|tags/, response.body)
      CatalogIndexer.new.consul
      get "/integrations/zabbix", headers: authorization
      assert_equal manual.id, response.parsed_body.fetch("certificates").first.fetch("id")
    end
  end

  test "only current retained configured inventory is monitored including expired and filesystem certificates" do
    cert = issue(expired: true).first
    current = store(cert, certid: "current")
    old = store(cert, certid: "old")
    archived = store(cert, certid: "archive")
    deleted = store(cert, certid: "deleted")
    retired = store(cert, certid: "retired")
    foreign = store(cert, certid: "foreign")
    old.update!(active: false)
    archived.update!(archived: true, rollout_status: "delete")
    deleted.update!(deleted_at: Time.current)
    retired.update!(rollout_status: "delete")
    foreign.update_columns(area: "removed_area")
    disk = CatalogIndexer.new.upsert(cert, area: "zone_a", source: "filesystem", source_id: "synthetic.pem#0", tags: [])
    get "/integrations/zabbix", headers: authorization
    assert_equal([current.id, disk.id], response.parsed_body.fetch("certificates").map { |entry| entry.fetch("id") })
  end

  test "provenance mapping is case insensitive with acme priority and conservative fallback" do
    [[nil, nil, "manual"], ["cci-ui", "operator", "manual"], ["puppet", "ACME-worker", "acme"],
      ["external", "puppet-agent", "puppet"], ["acme.sh", nil, "acme"]].each do |client, actor, expected|
      assert_equal expected, Certificate.new(client: client, created_by: actor).renewal_mode
    end
  end

  test "token neither creates a UI session nor grants certificate access or writes" do
    get "/integrations/zabbix", headers: authorization
    assert_response :success
    get "/certificates", headers: authorization
    assert_redirected_to login_path
    post "/integrations/zabbix", headers: authorization
    assert_response :not_found
    post "/imports", headers: authorization
    assert_redirected_to login_path
  end

  test "successful empty inventory is a valid response" do
    get "/integrations/zabbix", headers: authorization
    assert_response :success
    assert_equal [], response.parsed_body.fetch("certificates")
  end

  test "central filtering redacts the configured token even from exception text" do
    token = ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")
    formatted = ContainerLogFormatter.new.call("ERROR", Time.current, nil,
      { message: "Failed with #{token}", authorization: "Bearer #{token}" })
    refute_includes formatted, token
    assert_includes formatted, "[FILTERED]"
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
                                             .filter("Authorization" => "Bearer #{token}", "token" => token)
    assert_equal({ "Authorization" => "[FILTERED]", "token" => "[FILTERED]" }, filtered)
  end

  test "inventory failures never expose interactive error details or establish sessions" do
    original = CertificateMonitoring.method(:snapshot)
    previous_details = Rails.application.config.x.show_error_details
    Rails.application.config.x.show_error_details = true
    token = ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")
    CertificateMonitoring.define_singleton_method(:snapshot) { raise "Synthetic failure #{token}" }
    get "/integrations/zabbix", headers: authorization
    assert_response :service_unavailable
    assert_empty response.body
    assert_nil response.headers["Set-Cookie"]
    assert_equal "no-store", response.headers["Cache-Control"]
  ensure
    CertificateMonitoring.define_singleton_method(:snapshot, original)
    Rails.application.config.x.show_error_details = previous_details
  end

  private

  def authorization
    { "Authorization" => "Bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")}" }
  end
end
