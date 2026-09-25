# frozen_string_literal: true

# Logs OIDC phases without claims, redirect URLs, codes, state or token responses.
module KeycloakLogging
  FAILURE_CODES = %w[csrf_detected invalid_state invalid_credentials timeout failed_to_connect connection_failed
    authentication_failed invalid_client unauthorized_client invalid_grant access_denied invalid_scope invalid_request
    invalid_signature invalid_nonce expired_token user_not_found user_disabled].freeze

  def request_phase
    OperationalLog.debug(logger: "cci.keycloak", message: "OIDC authentication request started",
      system: "keycloak", operation: "authentication_request")
    result = super
    OperationalLog.debug(logger: "cci.keycloak", message: "OIDC authentication redirect created",
      system: "keycloak", operation: "authentication_request", http_status: result[0])
    result
  rescue StandardError => e
    fail!(:connection_failed, e)
  end

  def callback_phase
    OperationalLog.debug(logger: "cci.keycloak", message: "OIDC callback processing started",
      system: "keycloak", operation: "authentication_callback")
    super
  rescue StandardError => e
    fail!(:authentication_failed, e)
  end

  def config
    with_oidc_phase("oidc_discovery") { super }
  end

  def access_token
    with_oidc_phase("token_exchange") { super }
  end

  def public_key
    with_oidc_phase("signing_keys") { super }
  end

  def user_info
    with_oidc_phase("userinfo") { super }
  end

  def decode_id_token(id_token)
    with_oidc_phase("identity_response_parsing", token_metadata(id_token)) { super }
  end

  # OmniAuth messages can contain provider-controlled URLs and response details.
  def log(level, _message)
    severity = %i[debug info warn error fatal].include?(level.to_sym) ? level.to_sym : :info
    OperationalLog.public_send(severity, logger: "cci.keycloak", message: "OIDC library event",
      system: "keycloak", operation: "omniauth")
  end

  def fail!(message, exception = nil)
    reason = FAILURE_CODES.include?(message.to_s) ? message.to_s : "authentication_rejected"
    log_safe_failure("Keycloak authentication failed", exception, reason)
    super(reason, exception)
  end

  private

  def log_safe_failure(message, exception, reason)
    original = exception || StandardError.new(reason)
    safe_error = StandardError.new(reason)
    safe_error.set_backtrace(original.backtrace)
    phase = original.instance_variable_get(:@cci_oidc_phase)
    metadata = original.instance_variable_get(:@cci_oidc_metadata) || {}
    OperationalLog.failure(logger: "cci.keycloak", message: message, error: safe_error, level: :warn,
      system: "keycloak", operation: "authentication", reason: reason,
      oidc_phase: phase, **metadata,
      upstream_error_type: original.class.name, diagnostic_reasons: diagnostic_reasons(original, phase),
      configuration: OperationalLog.configuration("oidc"))
  end

  def with_oidc_phase(phase, metadata = {})
    yield
  rescue StandardError => e
    unless e.instance_variable_defined?(:@cci_oidc_phase)
      e.instance_variable_set(:@cci_oidc_phase, phase)
      e.instance_variable_set(:@cci_oidc_metadata, metadata)
    end
    raise
  end

  def token_metadata(token)
    segments = token.to_s.split(".", -1)
    format = case segments.length
             when 3 then "signed_jwt"
             when 5 then "encrypted_jwe"
             else "unexpected_compact_serialization"
             end
    { identity_format: format, compact_segment_count: segments.length }
  end

  def diagnostic_reasons(error, phase)
    reasons = OperationalLog.reasons(error)
    return reasons unless error.is_a?(JSON::ParserError) && phase == "identity_response_parsing"

    reasons.reject { |value| value == "invalid JSON data (content omitted)" } +
      ["ID token header or payload is not valid JSON (token omitted)"]
  end
end
