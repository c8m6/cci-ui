# frozen_string_literal: true

require "test_helper"
require "stringio"
require "keycloak_logging"

class OperationalLogTest < ActiveSupport::TestCase
  test "causes explain TLS failures without exposing exception bodies" do
    error = begin
      begin
        raise OpenSSL::SSL::SSLError, "certificate verify failed secret-token-value"
      rescue OpenSSL::SSL::SSLError
        raise ConsulConnection::Error, "wrapped secret-token-value"
      end
    rescue ConsulConnection::Error => e
      e
    end
    output, = capture_io { OperationalLog.failure("health.failed", error, service: "consul") }
    event = JSON.parse(output)
    assert_equal(%w[ConsulConnection::Error OpenSSL::SSL::SSLError], event.fetch("causes").map { |cause| cause.fetch("type") })
    assert_includes output, "check CA trust"
    assert_not_includes output, "secret-token-value"
  end

  test "actual SQL writes include bulk operations but never bind values" do
    output, = capture_io do
      ImportDraft.where(id: -1).update_all(owner: "private-owner-token")
      ImportDraft.where(id: -1).delete_all
    end
    events = output.lines.filter_map do |line|
      JSON.parse(line) if line.start_with?("{")
    end
    writes = events.select { |event| event["event"] == "database.write" }
    assert(writes.any? { |event| event["operation"] == "UPDATE" && event["table"] == "import_drafts" })
    assert(writes.any? { |event| event["operation"] == "DELETE FROM" && event["table"] == "import_drafts" })
    assert_not_includes output, "private-owner-token"
  end

  test "startup reports health failure causes without aborting the application" do
    original_health = ApplicationHealth.method(:check)
    original_ready = ApplicationReadiness.method(:check)
    ApplicationHealth.define_singleton_method(:check) { { "consul" => Errno::ECONNREFUSED.new } }
    ApplicationReadiness.define_singleton_method(:check) { {} }
    output, = capture_io { OperationalLog.startup }
    assert_includes output, "startup.health.failed"
    assert_includes output, "connection refused"
    assert_includes output, '"outcome":"unhealthy"'
  ensure
    ApplicationHealth.define_singleton_method(:check, original_health)
    ApplicationReadiness.define_singleton_method(:check, original_ready)
  end

  test "Keycloak connection failure is logged and sent through the failure handler" do
    base = Class.new do
      def request_phase
        raise SocketError, "private-provider-response"
      end

      def fail!(_message, _exception = nil)
        [302, {}, []]
      end
    end
    base.prepend(KeycloakLogging)
    output, = capture_io { assert_equal 302, base.new.request_phase.first }
    assert_includes output, "keycloak.request.failed"
    assert_includes output, "check DNS resolution"
    assert_not_includes output, "private-provider-response"
  end

  test "Keycloak authentication failure retains known reason without provider response" do
    base = Class.new do
      def fail!(_message, _exception = nil)
        [302, {}, []]
      end
    end
    base.prepend(KeycloakLogging)
    output, = capture_io { base.new.fail!("invalid_client", StandardError.new("private-provider-response")) }
    assert_includes output, '"reason":"invalid_client"'
    assert_not_includes output, "private-provider-response"
    output, = capture_io { base.new.fail!("private-provider-response") }
    assert_includes output, '"reason":"authentication_rejected"'
    assert_not_includes output, "private-provider-response"
  end

  test "Consul logs write outcomes without values and ignores read operations" do
    connection = ConsulConnection.new
    connection.define_singleton_method(:request) { |*_args, **_options| {} }
    operations = [{ "Verb" => "get", "Key" => "read" }, ConsulConnection.set("write", "private-material")]
    output, = capture_io { connection.transaction(operations) }
    events = output.lines.map { |line| JSON.parse(line) }
    assert_equal(%w[attempted succeeded], events.map { |event| event["outcome"] })
    assert_equal 1, events.map { |event| event["transaction_id"] }.uniq.size
    assert_not_includes output, "private-material"
    assert_not_includes output, Base64.strict_encode64("private-material")
    connection.define_singleton_method(:request) { |*_args, **_options| raise ConsulConnection::Conflict }
    output, = capture_io { assert_raises(ConsulConnection::Conflict) { connection.transaction(operations) } }
    assert_includes output, '"outcome":"rejected"'
    assert_not_includes output, '"outcome":"succeeded"'
  end

  test "framework formatter removes PEM secrets and OIDC redirect queries" do
    previous = ENV.fetch("OIDC_CLIENT_SECRET", nil)
    ENV["OIDC_CLIENT_SECRET"] = "test-secret-value"
    formatter = ContainerLogFormatter.new
    text = "test-secret-value https://keycloak.test/auth?code=private-code&state=private-state " \
           "-----BEGIN PRIVATE KEY-----\nprivate-key-data\n-----END PRIVATE KEY-----"
    output = formatter.call("ERROR", Time.now, nil, text)
    %w[test-secret-value private-code private-state private-key-data].each do |value|
      assert_not_includes output, value
    end
  ensure
    previous ? ENV["OIDC_CLIENT_SECRET"] = previous : ENV.delete("OIDC_CLIENT_SECRET")
  end
end
