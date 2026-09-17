class SessionsController < ApplicationController
  skip_before_action :require_identity
  def self.local_identities
    groups = {
      "reader" => ["Reader", %w[reader]], "writer" => ["Writer", %w[writer]],
      "keys" => ["Writer + Key Exporter", %w[writer key_exporter]], "auditor" => ["Auditor", %w[auditor]]
    }
    identities = AreaConfiguration.ids.each_with_object({}) do |area, result|
      groups.each do |suffix, (label, roles)|
        result["#{area}_#{suffix}"] = ["#{AreaConfiguration.label(area)} · #{label}", roles.map { |role| "#{area}_#{role}" }]
      end
    end
    groups.each do |suffix, (label, roles)|
      identities["all:#{suffix}"] = ["#{I18n.t('ui.all_areas')} · #{label}", AreaConfiguration.ids.product(roles).map { |area, role| "#{area}_#{role}" }]
    end
    identities
  end

  def new; end
  def local
    return head :not_found unless ENV["AUTH_MODE"] == "local" && !Rails.env.production?
    identity = self.class.local_identities[params[:identity]]
    return head :unprocessable_entity unless identity
    establish(identity[0], identity[1])
  end
  def callback
    auth = request.env["omniauth.auth"]
    return head :unauthorized unless auth && auth.provider == "keycloak" && ENV.fetch("AUTH_MODE", "oidc") == "oidc"
    info = auth.extra.raw_info.to_h.deep_stringify_keys
    supplied = Array(info["groups"]) + Array(info.dig("realm_access", "roles")) + Array(info.dig("resource_access", ENV["OIDC_CLIENT_ID"], "roles"))
    mapping = JSON.parse(ENV.fetch("OIDC_ROLE_MAP", "{}"))
    roles = supplied.map { |role| mapping.fetch(role, role) }.flatten
    establish(auth.uid.to_s, Identity.new(name: auth.uid, roles: roles).roles)
  end
  def failure
    redirect_to login_path, alert: I18n.t("errors.app.sso_failed")
  end
  def destroy
    reset_session
    redirect_to login_path, status: :see_other
  end
  private
  def establish(name, roles)
    reset_session
    session[:identity] = { name: name, roles: roles }
    session[:authenticated_at] = Time.current.to_i
    session[:import_owner] = SecureRandom.hex(24)
    identity = Identity.new(name: name, roles: roles)
    redirect_to(identity.areas.empty? && identity.auditor? ? audit_events_path : root_path, status: :see_other)
  end
end
