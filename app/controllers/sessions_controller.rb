# frozen_string_literal: true

# Establishes identities from local development accounts or validated OIDC claims.
class SessionsController < ApplicationController
  skip_before_action :require_identity
  def self.local_identities
    groups = {
      "reader" => ["Reader", %w[reader]], "writer" => ["Writer", %w[writer]],
      "exporter" => ["Key Exporter", %w[key_exporter]], "auditor" => ["Auditor", %w[auditor]],
      "csr" => ["CSR", %w[csr]]
    }
    identities = AreaConfiguration.ids.each_with_object({}) do |area, result|
      groups.each do |suffix, (label, roles)|
        result["#{area}_#{suffix}"] = ["#{AreaConfiguration.label(area)} · #{label}", roles.map do |role|
          "#{area}_#{role}"
        end]
      end
    end
    groups.each do |suffix, (label, roles)|
      identities["all:#{suffix}"] = ["#{I18n.t("ui.all_areas")} · #{label}", AreaConfiguration.ids.product(roles).map do |area, role|
        "#{area}_#{role}"
      end]
    end
    identities
  end

  def new; end

  def local
    return render_error(:not_found) unless ENV["AUTH_MODE"] == "local" && !Rails.env.production?

    identity = self.class.local_identities[params[:identity]]
    return render_error(:unprocessable_content) unless identity

    establish(identity[0], identity[1])
  end

  def callback
    auth = request.env["omniauth.auth"]
    result = OidcAuthorization.new(auth: auth, auth_mode: ENV.fetch("AUTH_MODE", "oidc"),
      client_id: ENV.fetch("OIDC_CLIENT_ID", ""),
      role_mapping: Rails.application.config.x.oidc_role_mapping || OidcConfiguration.load_role_mapping,
      display_name_claim: Rails.application.config.x.oidc_display_name_claim ||
        OidcConfiguration.display_name_claim).call
    log_oidc_evaluation(result)
    unless result.allowed?
      log_oidc_denial(reason: result.reason, failure_detail: result.failure_detail, **result.details)
      return reject_oidc_access if result.identity

      return render_error(:unauthorized)
    end

    grant_oidc_access(result)
  end

  def failure
    provider_reason = oidc_failure_reason
    reason = %w[user_not_found user_disabled].include?(provider_reason) ? provider_reason : "authentication_failed"
    log_oidc_denial(reason: reason, failure_detail: provider_reason)
    redirect_to login_path, alert: I18n.t("errors.app.sso_failed")
  end

  def destroy
    reset_session
    redirect_to login_path, status: :see_other
  end

  private

  def grant_oidc_access(result)
    identity = result.identity
    OperationalLog.debug(logger: "cci.authorization", message: "Authorization granted",
      system: "keycloak", operation: "authorization", result: "allowed", decision: "granted",
      user: identity.uid, display_name: identity.display_name,
      display_name_source: result.details.fetch(:display_name_source),
      client_id: result.details.fetch(:client_id), realm: keycloak_realm,
      required_roles: result.details.fetch(:required_roles), effective_roles: identity.roles)
    establish(identity.uid, identity.roles, display_name: identity.display_name)
  end

  def reject_oidc_access
    reset_session
    redirect_to login_path, alert: I18n.t("errors.app.no_assigned_rights"), status: :see_other
  end

  def log_oidc_evaluation(result)
    details = result.details
    OperationalLog.debug(logger: "cci.keycloak", message: "OIDC callback evaluated",
      system: "keycloak", operation: "authentication_callback", realm: keycloak_realm,
      **details.slice(:auth_present, :auth_mode, :provider, :expected_provider, :client_id,
        :identity_source, :user, :display_name, :display_name_source,
        :claim_paths_checked, :relevant_claims_present, :missing_claims))
    return unless result.identity

    OperationalLog.debug(logger: "cci.authorization", message: "Evaluating OIDC authorization",
      system: "keycloak", operation: "authorization", realm: keycloak_realm,
      **details.slice(:user, :identity_source, :display_name, :display_name_source,
        :client_id, :claim_paths_checked, :relevant_claims_present,
        :role_sources, :group_roles, :realm_roles, :client_roles, :incoming_roles, :matched_role_mappings,
        :mapped_roles, :accepted_application_roles, :discarded_roles, :required_roles, :effective_roles))
  end

  def log_oidc_denial(reason:, failure_detail:, **details)
    OperationalLog.debug(logger: "cci.authorization", message: "Authorization denied",
      system: "keycloak", operation: "authorization", result: "denied", decision: "denied",
      reason: reason, failure_detail: failure_detail, realm: keycloak_realm,
      **details.slice(:user, :display_name, :display_name_source, :client_id, :provider, :expected_provider, :auth_mode,
        :claim_paths_checked, :relevant_claims_present, :missing_claims, :role_sources,
        :group_roles, :realm_roles, :client_roles, :incoming_roles, :matched_role_mappings,
        :mapped_roles, :accepted_application_roles, :discarded_roles, :required_roles, :effective_roles))
  end

  def oidc_failure_reason
    value = request.env["omniauth.error.type"].presence || params[:message].presence
    allowed = KeycloakLogging::FAILURE_CODES + %w[authentication_rejected user_not_found user_disabled]
    allowed.include?(value.to_s) ? value.to_s : "authentication_rejected"
  end

  def keycloak_realm
    URI(ENV.fetch("OIDC_ISSUER")).path.split("/").reject(&:empty?).last
  rescue URI::InvalidURIError
    nil
  end

  def establish(uid, roles, display_name: uid)
    reset_session
    session[:identity] = { uid: uid, display_name: display_name, roles: roles }
    session[:authenticated_at] = Time.current.to_i
    session[:import_owner] = SecureRandom.hex(24)
    identity = Identity.new(uid: uid, display_name: display_name, roles: roles)
    return redirect_to certificate_requests_path, status: :see_other if identity.areas.empty? && identity.any_csr?

    redirect_to(identity.areas.empty? && identity.auditor? ? audit_events_path : root_path, status: :see_other)
  end
end
