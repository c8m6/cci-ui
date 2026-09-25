# frozen_string_literal: true

require "test_helper"
require "stringio"
require "keycloak_logging"
require "keycloak_http_logging"
require "request_log_context"

class OperationalLogTest < ActiveSupport::TestCase
  setup do
    @original_logger = OperationalLog.target
  end

  teardown do
    OperationalLog.configure(@original_logger)
  end

  test "every application event uses the JSON base schema and structured context" do
    output = with_log_output do
      LogContext.with(request_id: "request-123") do
        OperationalLog.info(logger: "cci.test", message: "Test event", operation: "verify_logging")
      end
    end
    event = JSON.parse(output)
    assert_equal %w[level logger message operation process request_id timestamp], event.keys.sort
    assert_equal "INFO", event["level"]
    assert_equal "cci.test", event["logger"]
    assert_equal "Test event", event["message"]
    assert_equal "request-123", event["request_id"]
  end

  test "exceptions include structured causes and redact configured credentials" do
    previous = ENV.fetch("OIDC_CLIENT_SECRET", nil)
    ENV["OIDC_CLIENT_SECRET"] = "secret-token-value"
    error = begin
      begin
        raise OpenSSL::SSL::SSLError, "certificate verify failed secret-token-value"
      rescue OpenSSL::SSL::SSLError
        raise ConsulConnection::Error, "wrapped secret-token-value"
      end
    rescue ConsulConnection::Error => e
      e
    end
    event = JSON.parse(with_log_output do
      OperationalLog.failure(logger: "cci.health", message: "Health check failed", error: error, service: "consul")
    end)
    assert_equal "ConsulConnection::Error", event["error_type"]
    cause_types = event.fetch("causes").map { |cause| cause.fetch("error_type") }
    assert_equal %w[ConsulConnection::Error OpenSSL::SSL::SSLError], cause_types
    assert_includes event.to_json, "check CA trust"
    assert_not_includes event.to_json, "secret-token-value"
    assert event["stacktrace"].is_a?(Array)
  ensure
    previous ? ENV["OIDC_CLIENT_SECRET"] = previous : ENV.delete("OIDC_CLIENT_SECRET")
  end

  test "database writes do not emit SQL or generic model events" do
    output = with_log_output do
      ImportDraft.where(id: -1).update_all(owner: "private-owner-token")
      ImportDraft.where(id: -1).delete_all
    end
    assert_empty output
  end

  test "startup reports health failure details without aborting the application" do
    original_health = ApplicationHealth.method(:check)
    original_ready = ApplicationReadiness.method(:check)
    ApplicationHealth.define_singleton_method(:check) { { "consul" => Errno::ECONNREFUSED.new } }
    ApplicationReadiness.define_singleton_method(:check) { {} }
    events = with_log_output { OperationalLog.startup }.lines.map { |line| JSON.parse(line) }
    failure = events.find { |event| event["message"] == "Startup health check failed" }
    assert_equal "consul", failure["service"]
    assert_includes failure.to_json, "connection refused"
    assert_equal "unhealthy", events.last["result"]
  ensure
    ApplicationHealth.define_singleton_method(:check, original_health)
    ApplicationReadiness.define_singleton_method(:check, original_ready)
  end

  test "Keycloak connection failure is safe and routed through the failure handler" do
    base = Class.new do
      def request_phase
        raise SocketError, "private-provider-response"
      end

      def fail!(_message, _exception = nil)
        [302, {}, []]
      end
    end
    base.prepend(KeycloakLogging)
    output = with_log_output { assert_equal 302, base.new.request_phase.first }
    assert_includes output, "Keycloak authentication"
    assert_includes output, "check DNS resolution"
    assert_not_includes output, "private-provider-response"
  end

  test "Keycloak authentication failure identifies invalid ID token JSON without logging the token" do
    base = Class.new do
      def callback_phase
        decode_id_token("private-header.private-payload.private-signature")
      end

      def decode_id_token(_token)
        raise JSON::ParserError, "private-token-parser-detail"
      end

      def fail!(_message, _exception = nil)
        [302, {}, []]
      end
    end
    base.prepend(KeycloakLogging)

    event = with_log_output { base.new.callback_phase }.lines.map { |line| JSON.parse(line) }.last
    assert_equal "identity_response_parsing", event["oidc_phase"]
    assert_equal "signed_jwt", event["identity_format"]
    assert_equal 3, event["compact_segment_count"]
    assert_equal ["ID token header or payload is not valid JSON (token omitted)"], event["diagnostic_reasons"]
    assert_not_includes event.to_json, "private-header"
    assert_not_includes event.to_json, "private-token-parser-detail"
  end

  test "invalid Keycloak response JSON logs the endpoint metadata without the body" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/realms/example/protocol/openid-connect/userinfo") do
        [200, { "Content-Type" => "application/json" }, "<private-html-response>"]
      end
    end
    connection = Faraday.new(url: "https://keycloak.example.test") do |faraday|
      faraday.use KeycloakHttpLogging
      faraday.response :json
      faraday.adapter :test, stubs
    end

    output = with_log_output do
      assert_raises(Faraday::ParsingError) do
        connection.get("/realms/example/protocol/openid-connect/userinfo")
      end
    end
    failure = output.lines.map { |line| JSON.parse(line) }.last
    assert_equal "Keycloak request failed", failure["message"]
    assert_equal "userinfo", failure["operation"]
    assert_equal 200, failure["http_status"]
    assert_equal "application/json", failure["content_type"]
    assert_equal 23, failure["response_bytes"]
    assert_equal "invalid_json_response", failure["reason"]
    assert_not_includes output, "private-html-response"
  end

  test "Keycloak authentication failure retains a known reason without provider response" do
    base = Class.new do
      def fail!(_message, _exception = nil)
        [302, {}, []]
      end
    end
    base.prepend(KeycloakLogging)
    output = with_log_output { base.new.fail!("invalid_client", StandardError.new("private-provider-response")) }
    assert_includes output, '"reason":"invalid_client"'
    assert_not_includes output, "private-provider-response"
    output = with_log_output { base.new.fail!("private-provider-response") }
    assert_includes output, '"reason":"authentication_rejected"'
    assert_not_includes output, "private-provider-response"
  end

  test "Keycloak HTTP logs upstream status and forwards the request ID without headers or bodies" do
    received = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/realms/example/.well-known/openid-configuration") do |env|
        received = env.request_headers["X-Request-Id"]
        [403, { "Content-Type" => "application/json" }, '{"access_token":"private"}']
      end
    end
    connection = Faraday.new(url: "https://keycloak.example.test") do |faraday|
      faraday.use KeycloakHttpLogging
      faraday.adapter :test, stubs
    end
    output = with_log_output do
      LogContext.with(request_id: "request-oidc") do
        connection.get("/realms/example/.well-known/openid-configuration")
      end
    end
    assert_equal "request-oidc", received
    completed = output.lines.map { |line| JSON.parse(line) }.last
    assert_equal 403, completed["http_status"]
    assert_equal "upstream_authentication_rejected", completed["result"]
    assert_equal "oidc_discovery", completed["operation"]
    assert_not_includes output, "private"
  end

  test "Consul logs write outcomes at DEBUG without values" do
    connection = ConsulConnection.new
    connection.define_singleton_method(:request) { |*_args, **_options| {} }
    operations = [{ "Verb" => "get", "Key" => "read" }, ConsulConnection.set("write", "private-material")]
    events = with_log_output { connection.transaction(operations) }.lines.map { |line| JSON.parse(line) }
    results = events.map { |event| event["result"] }
    assert_equal %w[attempted succeeded], results
    assert_equal 1, events.map { |event| event["consul_transaction_id"] }.uniq.size
    assert_not_includes events.to_json, "private-material"
    connection.define_singleton_method(:request) { |*_args, **_options| raise ConsulConnection::Conflict }
    output = with_log_output { assert_raises(ConsulConnection::Conflict) { connection.transaction(operations) } }
    assert_includes output, '"result":"rejected"'
    assert_not_includes output, '"result":"succeeded"'
  end

  test "formatter removes credentials PEM data OIDC queries and JWTs" do
    previous = ENV.fetch("OIDC_CLIENT_SECRET", nil)
    ENV["OIDC_CLIENT_SECRET"] = "test-secret-value"
    formatter = ContainerLogFormatter.new
    message = "test-secret-value https://keycloak.test/auth?code=private-code&state=private-state " \
              "eyJheader.payload.signature -----BEGIN PRIVATE KEY-----\nprivate-key-data\n-----END PRIVATE KEY-----"
    output = formatter.call("ERROR", Time.now, nil, message)
    event = JSON.parse(output)
    assert_equal %w[level logger message timestamp], event.keys.sort
    %w[test-secret-value private-code private-state private-key-data eyJheader].each do |value|
      assert_not_includes output, value
    end
  ensure
    previous ? ENV["OIDC_CLIENT_SECRET"] = previous : ENV.delete("OIDC_CLIENT_SECRET")
  end

  test "framework exception strings become structured JSON errors" do
    formatter = ContainerLogFormatter.new
    output = formatter.call("FATAL", Time.now, nil,
      "NameError (broken request):\n/app/example.rb:12:in 'call'\n")
    event = JSON.parse(output)
    assert_equal "Unhandled exception", event["message"]
    assert_equal "NameError", event["error_type"]
    assert_equal "broken request", event["error_message"]
    assert_equal ["/app/example.rb:12:in 'call'"], event["stacktrace"]
  end

  test "Puma stdout and stderr use the application JSON schema" do
    previous = ENV.fetch("LOG_LEVEL", nil)
    ENV["LOG_LEVEL"] = "DEBUG"
    output = StringIO.new
    PumaJsonOutput.new(output, level: "INFO").write("Puma started\n")
    PumaJsonOutput.new(output, level: "ERROR").write("listener failed\n")
    info, error = output.string.lines.map { |line| JSON.parse(line) }
    assert_equal %w[timestamp level logger message], info.keys
    assert_equal "puma", info["logger"]
    assert_equal "Puma started", info["message"]
    assert_equal "PumaError", error["error_type"]
    assert_equal "listener failed", error["error_message"]

    ENV["LOG_LEVEL"] = "ERROR"
    suppressed = StringIO.new
    assert_equal 0, PumaJsonOutput.new(suppressed, level: "INFO").write("hidden")
    assert_empty suppressed.string
  ensure
    previous ? ENV["LOG_LEVEL"] = previous : ENV.delete("LOG_LEVEL")
  end

  test "invalid LOG_LEVEL falls back to INFO" do
    assert_equal [:debug, nil], OperationalLog.resolve_level("debug")
    assert_equal [:warn, nil], OperationalLog.resolve_level("WARNING")
    assert_equal [:info, "verbose"], OperationalLog.resolve_level("verbose")
  end

  test "request middleware validates IDs and emits one correlated completion event" do
    app = lambda do |env|
      [204, {}, [env.fetch("action_dispatch.request_id")]]
    end
    middleware = RequestLogContext.new(app)
    output = with_log_output do
      status, headers, body = middleware.call(
        "HTTP_X_REQUEST_ID" => "unsafe\nvalue", "REQUEST_METHOD" => "GET", "PATH_INFO" => "/health"
      )
      assert_equal 204, status
      assert_match(/\A[0-9a-f-]{36}\z/, headers["X-Request-Id"])
      assert_equal headers["X-Request-Id"], body.first
    end
    event = JSON.parse(output)
    assert_equal "/health", event["endpoint"]
    assert_equal 204, event["http_status"]
    assert_match(/\A[0-9a-f-]{36}\z/, event["request_id"])
  end

  private

  def with_log_output(level: Logger::DEBUG)
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.formatter = ContainerLogFormatter.new
    logger.level = level
    OperationalLog.configure(logger)
    yield
    output.string
  ensure
    OperationalLog.configure(@original_logger)
  end
end
