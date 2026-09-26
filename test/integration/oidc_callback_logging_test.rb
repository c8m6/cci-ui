# frozen_string_literal: true

require "test_helper"
require "stringio"

class OidcCallbackLoggingTest < ActionDispatch::IntegrationTest
  setup do
    @environment = ENV.to_h.slice(
      "AUTH_MODE", "OIDC_CLIENT_ID", "OIDC_ISSUER", "OIDC_ROLE_MAP", "OIDC_DISPLAY_NAME_CLAIM"
    )
    ENV["AUTH_MODE"] = "oidc"
    ENV["OIDC_CLIENT_ID"] = "cci-ui"
    ENV["OIDC_ISSUER"] = "https://keycloak.example.test/realms/example"
    ENV["OIDC_ROLE_MAP"] = JSON.generate("/cci/editors" => "zone_a_writer", "cci-reader" => "zone_b_reader")
    ENV["OIDC_DISPLAY_NAME_CLAIM"] = "preferred_username"
    @original_role_mapping = Rails.application.config.x.oidc_role_mapping
    @original_display_name_claim = Rails.application.config.x.oidc_display_name_claim
    Rails.application.config.x.oidc_role_mapping = OidcConfiguration.load_role_mapping
    Rails.application.config.x.oidc_display_name_claim = OidcConfiguration.display_name_claim
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
    %w[AUTH_MODE OIDC_CLIENT_ID OIDC_ISSUER OIDC_ROLE_MAP OIDC_DISPLAY_NAME_CLAIM].each do |name|
      @environment.key?(name) ? ENV[name] = @environment.fetch(name) : ENV.delete(name)
    end
    Rails.application.config.x.oidc_role_mapping = @original_role_mapping
    Rails.application.config.x.oidc_display_name_claim = @original_display_name_claim
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
    assert_equal "example", evaluation["display_name"]
    assert_equal "preferred_username", evaluation["display_name_source"]
    assert_equal "cci-ui", evaluation["client_id"]
    assert_equal ["/cci/editors"], evaluation["group_roles"]
    assert_equal ["default-roles-example"], evaluation["realm_roles"]
    assert_equal ["cci-reader"], evaluation["client_roles"]
    assert_equal ["groups", "realm_access.roles", "resource_access.cci-ui.roles"], evaluation["role_sources"]
    assert_equal [], evaluation["required_roles"]
    assert_equal %w[zone_a_writer zone_b_reader], evaluation["effective_roles"]
    assert_equal ["default-roles-example"], evaluation["discarded_roles"]
    granted = events.find { |event| event["decision"] == "granted" }
    assert_equal "allowed", granted["result"]
    assert_equal "keycloak-user-42", granted["user"]
    assert_equal "example", granted["display_name"]
    assert_equal "preferred_username", granted["display_name_source"]
    follow_redirect!
    assert_select ".account-name", text: "example"
    assert_not_includes @log_output.string, "private-access-token"
    assert_not_includes @log_output.string, "private-other-role"
  end

  test "configured display name is independent from the stable user identity" do
    Rails.application.config.x.oidc_display_name_claim = "name"
    raw_info = {
      "sub" => "keycloak-user-42", "preferred_username" => "example",
      "name" => "Example User", "email" => "example@example.test",
      "groups" => ["/cci/editors"]
    }

    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash(raw_info: raw_info) }

    assert_response :see_other
    evaluation = events.find { |event| event["message"] == "Evaluating OIDC authorization" }
    assert_equal "keycloak-user-42", evaluation["user"]
    assert_equal "Example User", evaluation["display_name"]
    assert_equal "name", evaluation["display_name_source"]
    follow_redirect!
    assert_select ".account-name", text: "Example User"
  end

  test "blank display claims fall back to email and then to the stable uid" do
    Rails.application.config.x.oidc_display_name_claim = "name"
    raw_info = {
      "sub" => "keycloak-user-42", "preferred_username" => "  ",
      "name" => "", "email" => "example@example.test", "groups" => ["/cci/editors"]
    }

    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash(raw_info: raw_info) }

    evaluation = events.find { |event| event["message"] == "Evaluating OIDC authorization" }
    assert_equal "example@example.test", evaluation["display_name"]
    assert_equal "email", evaluation["display_name_source"]

    delete logout_path
    @log_output.truncate(0)
    @log_output.rewind
    get "/auth/keycloak/callback", env: {
      "omniauth.auth" => auth_hash(raw_info: {
        "sub" => "keycloak-user-42", "groups" => ["/cci/editors"]
      })
    }

    evaluation = events.find { |event| event["message"] == "Evaluating OIDC authorization" }
    assert_equal "keycloak-user-42", evaluation["display_name"]
    assert_equal "omniauth.uid", evaluation["display_name_source"]
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
    assert_equal "denied", denial["decision"]
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

  test "an identity without roles is signed out with a clear message" do
    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash }

    assert_response :see_other
    assert_redirected_to login_path
    denial = events.find { |event| event["reason"] == "no_roles_received" }
    assert_equal "denied", denial["result"]
    assert_equal "role_claims_empty", denial["failure_detail"]
    assert_equal [], denial["effective_roles"]
    assert_not(events.any? { |event| event["decision"] == "granted" })

    follow_redirect!
    expected = I18n.t("errors.app.no_assigned_rights", locale: :de)
    assert_select ".flash-error", text: expected
    assert_select ".account-name", count: 0
  end

  test "an identity with no applicable CCI role is signed out as required_role_missing" do
    raw_info = {
      "sub" => "keycloak-user-42", "preferred_username" => "example",
      "realm_access" => { "roles" => ["default-roles-example"] }
    }

    get "/auth/keycloak/callback", env: { "omniauth.auth" => auth_hash(raw_info: raw_info) }

    assert_response :see_other
    assert_redirected_to login_path
    denial = events.find { |event| event["reason"] == "required_role_missing" }
    assert_equal "denied", denial["decision"]
    assert_equal "no_application_roles", denial["failure_detail"]
    assert_equal ["default-roles-example"], denial["incoming_roles"]
    assert_equal ["default-roles-example"], denial["discarded_roles"]
    assert_equal [], denial["effective_roles"]
    assert_not(events.any? { |event| event["decision"] == "granted" })
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
