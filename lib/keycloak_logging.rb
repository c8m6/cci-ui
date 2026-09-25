# frozen_string_literal: true

# Logs OIDC phases without claims, redirect URLs, codes, state or token responses.
module KeycloakLogging
  FAILURE_CODES = %w[csrf_detected invalid_state invalid_credentials timeout failed_to_connect connection_failed
    authentication_failed invalid_client unauthorized_client invalid_grant access_denied invalid_scope invalid_request
    invalid_signature invalid_nonce expired_token].freeze
  def request_phase
    OperationalLog.emit("keycloak.request.started")
    result = super
    OperationalLog.emit("keycloak.request.completed", status: result[0])
    result
  rescue StandardError => e
    OperationalLog.failure("keycloak.request.failed", e, configuration: OperationalLog.configuration("oidc"))
    fail!(:connection_failed, e)
  end

  def callback_phase
    OperationalLog.emit("keycloak.callback.started")
    super
  rescue StandardError => e
    OperationalLog.failure("keycloak.callback.failed", e, configuration: OperationalLog.configuration("oidc"))
    fail!(:authentication_failed, e)
  end

  # OmniAuth otherwise logs provider-controlled exception messages and responses.
  def log(level, _message)
    OperationalLog.emit("keycloak.library", level: level)
  end

  def fail!(message, exception = nil)
    error = exception || StandardError.new
    reason = FAILURE_CODES.include?(message.to_s) ? message.to_s : "authentication_rejected"
    OperationalLog.failure("keycloak.authentication.failed", error, reason: reason)
    super(reason, exception)
  end
end
