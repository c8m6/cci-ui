# frozen_string_literal: true

require "test_helper"

class ReadinessTest < ActionDispatch::IntegrationTest
  test "readiness succeeds without changing connection timeouts or data" do
    connection = ActiveRecord::Base.connection
    timeout = connection.select_value("SHOW statement_timeout")
    counts = [Certificate.count, AuditEvent.count]
    get "/ready"
    assert_response :ok
    assert_equal "ok", response.parsed_body.fetch("status")
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal timeout, connection.select_value("SHOW statement_timeout")
    assert_equal counts, [Certificate.count, AuditEvent.count]
    head "/ready"
    assert_response :ok
    assert_empty response.body
  end

  test "pending migrations make the replica unready without running them" do
    connection = ActiveRecord::Base.connection
    version = connection.select_value("SELECT MAX(version) FROM schema_migrations")
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(version)}")
    get "/ready"
    assert_response :service_unavailable
    assert_not response.parsed_body.key?("failures")
    assert_not connection.pool.migration_context.get_all_versions.include?(version.to_i)
    get "/up"
    assert_response :ok
  end

  test "database outage affects readiness but not process liveness" do
    pool = ActiveRecord::Base.connection_pool
    original = pool.method(:with_connection)
    pool.define_singleton_method(:with_connection) { |**_options, &_block| raise ActiveRecord::ConnectionNotEstablished, "offline" }
    get "/ready"
    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
    get "/up"
    assert_response :ok
  ensure
    pool.define_singleton_method(:with_connection, original) if original
  end

  test "read-only databases are unready" do
    connection = ActiveRecord::Base.connection
    original = connection.method(:select_value)
    connection.define_singleton_method(:select_value) do |sql, *args, **options|
      sql.include?("pg_is_in_recovery()") || original.call(sql, *args, **options)
    end
    get "/ready"
    assert_response :service_unavailable
  ensure
    connection.define_singleton_method(:select_value, original) if original
  end

  test "Consul outage does not prevent login catalog or audit access" do
    original = ConsulStore.method(:client)
    ConsulStore.define_singleton_method(:client) { raise ConsulConnection::Error, "offline" }
    post local_login_path, params: { identity: "zone_a_writer" }
    assert_response :redirect
    get root_path
    assert_response :ok
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path
    assert_response :ok
    get "/ready"
    assert_response :ok
    get "/health"
    assert_response :service_unavailable
  ensure
    ConsulStore.define_singleton_method(:client, original) if original
  end
end
