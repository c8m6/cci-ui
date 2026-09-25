# frozen_string_literal: true

# Authenticates requests and applies area-specific permissions before actions run.
class ApplicationController < ActionController::Base
  include WebContext
  include ErrorPages

  before_action :require_identity
  rescue_from Certificates::Error do |error|
    OperationalLog.failure(logger: "cci.certificates", message: "Certificate operation failed", error: error)
    redirect_back fallback_location: root_path, alert: error.message, status: :see_other
  end

  private

  def require_identity
    redirect_to login_path unless current_identity
  end

  def log_authorization_denied(required_roles:)
    identity = current_identity
    effective_roles = identity&.roles || []
    OperationalLog.debug(logger: "cci.authorization", message: "Authorization denied",
      system: ENV.fetch("AUTH_MODE", "oidc") == "oidc" ? "keycloak" : "cci-ui", operation: "authorization",
      result: "denied", decision: "denied", user: identity&.name, required_roles: required_roles,
      effective_roles: effective_roles, missing_roles: required_roles - effective_roles,
      reason: identity ? "required_role_missing" : "identity_missing")
  end

  def require_writer!(area)
    return if current_identity.writer?(area)

    log_authorization_denied(required_roles: ["#{area}_writer"])
    raise Certificates::Error,
      I18n.t("errors.app.writer_required",
        area: AreaConfiguration.label(area))
  end
end
