# frozen_string_literal: true

require "test_helper"
require "stringio"

class OidcCallbackLoggingTest < ActionDispatch::IntegrationTest
  setup do
    @environment = ENV.to_h.slice("AUTH_MODE", "OIDC_CLIENT_ID", "OIDC_ISSUER", "OIDC_ROLE_MAP")
    ENV["AUTH_MODE"] = "oidc"
    ENV["OIDC_CLIENT_ID"] = "cci-ui"
    ENV["OIDC_ISSUER"] = "https://keycloak.example.test/realms/example"
    ENV["OIDC_ROLE_MAP"] = JSON.generate("/cci/editors" => "zone_a_writer", "cci-reader" => "zone_b_reader")
    @log_output = StringIO.new
    @original_logger = Rails.logger
    @original_request_logger = Rails.application.env_config["action_dispatch.logger"]
    Rails.logger = ActiveSupport::Logger.new(@log_output)
    Rails.logger.formatter = ContainerLogFormatter.new
    Rails.logger.level = Logger::DEBUG
    OperationalLog.configure(Rails.logger)
    Rails.application.env_config["action_dispatch.logger"] = Rails.logger
  end

  teardown do
    %w[AUTH_MODE OIDC_CLIENT_ID OIDC_ISSUER OIDC_ROLE_MAP].each do |name|
      @environment.key?(name) ? ENV[name] = @environment.fetch(name) : ENV.delete(name)
    end
    Rails.application.env_config["action_dispatch.logger"] = @original_request_logger
    Rails.logger = @original_logger
    OperationalLog.configure(@original_logger)
  end

  test "symbol Keycloak provider establishes a session and logs the complete role decision" do
    raw_info = {
      "sub" => "keycloak-user-42", "preferred_username" => "example",
      "groups" => ["/cci/editors"],
      "realm_access" => { "roles" => ["default-roles-example"] },
      "resource_access" => {
        "cci-ui" => { "roles" => ["cci-reader"] },
        "another-client" => { "roles" => ["private-other-role"] }
      },
      "access_token" => "private-access-token"
    }
    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash(raw_info: raw_info) }

    assert_response :see_other
    assert_redirected_to root_path
    evaluation = events.find { |event| event["message"] == "Evaluating OIDC authorization" }
    assert_equal "keycloak-user-42", evaluation["user"]
    assert_equal "cci-ui", evaluation["client_id"]
    assert_equal ["/cci/editors"], evaluation["group_roles"]
    assert_equal ["default-roles-example"], evaluation["realm_roles"]
    assert_equal ["cci-reader"], evaluation["client_roles"]
    assert_equal ["groups", "realm_access.roles", "resource_access.cci-ui.roles"], evaluation["role_sources"]
    assert_equal [], evaluation["required_roles"]
    assert_equal %w[zone_a_writer zone_b_reader], evaluation["effective_roles"]
    assert_equal ["default-roles-example"], evaluation["discarded_roles"]
    granted = events.find { |event| event["state"] == "authorization_granted" }
    assert_equal "allowed", granted["result"]
    assert_not_includes @log_output.string, "private-access-token"
    assert_not_includes @log_output.string, "private-other-role"
  end

  test "missing auth hash logs identity_missing immediately before the application 401" do
    get "/auth/keycloak/callback"

    assert_response :unauthorized
    denial_index = events.index { |event| event["message"] == "Authorization denied" }
    http_index = events.index { |event| event["message"] == "HTTP error response" }
    assert denial_index
    assert http_index
    assert_operator denial_index, :<, http_index
    denial = events.fetch(denial_index)
    assert_equal "authorization_denied", denial["state"]
    assert_equal "identity_missing", denial["reason"]
    assert_equal "omniauth_auth_missing", denial["failure_detail"]
    assert_equal 401, events.fetch(http_index)["http_status"]
  end

  test "missing identity claim and disabled user have distinct denial reasons" do
    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash(uid: nil) }
    assert_response :unauthorized
    denial = events.reverse.find { |event| event["message"] == "Authorization denied" }
    assert_equal "required_claim_missing", denial["reason"]
    assert_equal ["omniauth.uid"], denial["missing_claims"]

    @log_output.truncate(0)
    @log_output.rewind
    get "/auth/keycloak/callback", env: {
      "omniauth.auth" => auth_hash(raw_info: { "sub" => "disabled-user", "enabled" => false })
    }
    assert_response :unauthorized
    denial = events.reverse.find { |event| event["message"] == "Authorization denied" }
    assert_equal "user_disabled", denial["reason"]
    assert_equal "enabled_claim_false", denial["failure_detail"]
  end

  test "an identity without roles logs no_roles_received and remains authenticated" do
    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash }

    assert_response :see_other
    no_roles = events.find { |event| event["state"] == "no_roles_received" }
    assert_equal "continued", no_roles["result"]
    assert_equal [], no_roles["effective_roles"]
    assert(events.any? { |event| event["state"] == "authorization_granted" })
  end

  test "OmniAuth failure preserves safe user states without logging provider input" do
    get "/auth/failure", params: { message: "user_not_found", provider_detail: "private-provider-value" }

    assert_response :redirect
    denial = events.find { |event| event["message"] == "Authorization denied" }
    assert_equal "user_not_found", denial["reason"]
    assert_equal "user_not_found", denial["failure_detail"]
    assert_not_includes @log_output.string, "private-provider-value"
  end

  private

  def auth_hash(uid: "keycloak-user-42", raw_info: { "sub" => "keycloak-user-42" }, provider: :keycloak)
    OmniAuth::AuthHash.new(provider: provider, uid: uid,
      credentials: { token: "private-token", refresh_token: "private-refresh-token" },
      extra: { raw_info: raw_info })
  end

  def events
    @log_output.string.lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
end
