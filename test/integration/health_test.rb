require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  test "health checks the configured dependencies without authentication" do
    get "/health"
    assert_response :ok
    assert_equal "ok", response.parsed_body.fetch("status")
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "dependency failures block pages and hide details unless enabled" do
    original = ApplicationHealth.method(:check)
    original_details = Rails.application.config.x.show_error_details
    ApplicationHealth.define_singleton_method(:check) do
      { "consul" => IOError.new("diagnostic <script>private</script>") }
    end
    [false, true].each do |details|
      Rails.application.config.x.show_error_details = details
      get "/health"
      assert_response :service_unavailable
      assert_equal details, response.parsed_body.key?("failures")
      get login_path
      assert_response :service_unavailable
      assert_select ".error-details", count: details ? 1 : 0
      assert_select ".error-details script", count: 0
      assert_not_includes response.body, "diagnostic" unless details
      head "/health"
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
    assert_response :service_unavailable
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
end
