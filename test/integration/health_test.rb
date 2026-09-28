# frozen_string_literal: true

require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  setup do
    @original_health_token = ENV.fetch("CCI_HEALTH_TOKEN", nil)
    ENV["CCI_HEALTH_TOKEN"] = "synthetic-health-token-for-tests"
    @original_cache = HealthController.cache
    HealthController.instance_variable_set(:@cache, HealthCheckCache.new)
  end

  teardown do
    ENV["CCI_HEALTH_TOKEN"] = @original_health_token
    HealthController.instance_variable_set(:@cache, @original_cache)
  end

  test "health checks the configured dependencies with a bearer token" do
    get "/health", headers: authorization
    assert_response :ok
    assert_equal "ok", response.parsed_body.fetch("status")
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "cached success expires and a failed dependency changes the response" do
    original = ApplicationHealth.method(:check)
    now = 0.0
    checks = 0
    HealthController.instance_variable_set(:@cache, HealthCheckCache.new(clock: -> { now }))
    ApplicationHealth.define_singleton_method(:check) do
      checks += 1
      checks == 1 ? {} : { "consul" => IOError.new("offline") }
    end

    2.times do
      get "/health", headers: authorization
      assert_response :ok
      assert_equal({ "status" => "ok" }, response.parsed_body)
    end
    assert_equal 1, checks

    get "/health", headers: { "Authorization" => "Bearer wrong" }
    assert_response :unauthorized
    assert_equal 1, checks

    now = 10.0
    get "/health", headers: authorization
    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal 2, checks
  ensure
    ApplicationHealth.define_singleton_method(:check, original) if original
  end

  test "missing configuration and invalid bearer tokens never run dependency checks" do
    original = ApplicationHealth.method(:check)
    ApplicationHealth.define_singleton_method(:check) { raise "Dependency check must not run" }

    ENV.delete("CCI_HEALTH_TOKEN")
    get "/health", headers: { "Authorization" => "Bearer synthetic-health-token-for-tests" }
    assert_response :service_unavailable
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_empty response.body

    ENV["CCI_HEALTH_TOKEN"] = " "
    get "/health", headers: authorization
    assert_response :service_unavailable

    ENV["CCI_HEALTH_TOKEN"] = "synthetic-health-token-for-tests"
    [nil, "Bearer", "Basic invalid", "Bearer wrong", "Bearer #{ENV.fetch("CCI_HEALTH_TOKEN")} extra"].each do |header|
      get "/health", headers: { "Authorization" => header }.compact
      assert_response :unauthorized
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_empty response.body
      refute_includes response.body, ENV.fetch("CCI_HEALTH_TOKEN")
    end
  ensure
    ApplicationHealth.define_singleton_method(:check, original) if original
  end

  test "dependency diagnostics do not block unrelated pages" do
    original = ApplicationHealth.method(:check)
    original_details = Rails.application.config.x.show_error_details
    ApplicationHealth.define_singleton_method(:check) do
      { "consul" => IOError.new("diagnostic <script>private</script>") }
    end
    [false, true].each do |details|
      Rails.application.config.x.show_error_details = details
      get "/health", headers: authorization
      assert_response :service_unavailable
      assert_equal details, response.parsed_body.key?("failures")
      get login_path
      assert_response :ok
      get "/ready"
      assert_response :ok
      assert_select ".error-details", count: 0
      assert_select ".error-details script", count: 0
      assert_not_includes response.body, "diagnostic" unless details
      head "/health", headers: authorization
      assert_response :service_unavailable
      assert_empty response.body
    end
    get "/up"
    assert_response :ok
  ensure
    ApplicationHealth.define_singleton_method(:check, original) if original
    Rails.application.config.x.show_error_details = original_details
  end

  test "a missing configured inventory is unhealthy" do
    original = AreaConfiguration.configuration
    configure_legacy_paths("zone_a" => File.join(TEST_LEGACY_ROOT, "missing-health-directory"))
    assert ApplicationHealth.check.key?("filesystem:zone_a")
    get login_path
    assert_response :ok
    get "/ready"
    assert_response :ok
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, original)
  end

  test "optional services are checked only when enabled" do
    previous = ENV.to_h.slice("PUPPETDB_ENABLED", "PUPPETDB_URL", "AUTH_MODE", "OIDC_ISSUER")
    ENV["PUPPETDB_ENABLED"] = "false"
    ENV["PUPPETDB_URL"] = "invalid"
    ENV["AUTH_MODE"] = "local"
    ENV["OIDC_ISSUER"] = "invalid"
    assert_empty ApplicationHealth.check
    ENV["PUPPETDB_ENABLED"] = "true"
    ENV["AUTH_MODE"] = "oidc"
    failures = ApplicationHealth.check
    assert failures.key?("puppetdb")
    assert failures.key?("oidc")
    get "/ready"
    assert_response :ok
    get login_path
    assert_response :ok
  ensure
    %w[PUPPETDB_ENABLED PUPPETDB_URL AUTH_MODE OIDC_ISSUER].each do |key|
      previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key)
    end
  end

  test "database and Consul failures are collected independently" do
    pool = ActiveRecord::Base.connection_pool
    original_database = pool.method(:with_connection)
    original_consul = ConsulStore.method(:client)
    pool.define_singleton_method(:with_connection) { |**_options, &_block| raise ActiveRecord::ConnectionNotEstablished, "offline" }
    ConsulStore.define_singleton_method(:client) { raise ConsulConnection::Error, "offline" }
    failures = ApplicationHealth.check
    assert failures.key?("postgresql")
    assert failures.key?("consul")
  ensure
    pool.define_singleton_method(:with_connection, original_database) if original_database
    ConsulStore.define_singleton_method(:client, original_consul) if original_consul
  end

  private

  def authorization
    { "Authorization" => "Bearer #{ENV.fetch("CCI_HEALTH_TOKEN")}" }
  end
end
