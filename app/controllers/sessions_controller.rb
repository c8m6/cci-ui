# frozen_string_literal: true

# Establishes identities from local development accounts or validated OIDC claims.
class SessionsController < ApplicationController
  skip_before_action :require_identity
  def self.local_identities
    groups = {
      "reader" => ["Reader", %w[reader]], "writer" => ["Writer", %w[writer]],
      "exporter" => ["Key Exporter", %w[key_exporter]], "auditor" => ["Auditor", %w[auditor]]
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
    return render_error(:unauthorized) unless auth && auth.provider == "keycloak" && ENV.fetch("AUTH_MODE",
      "oidc") == "oidc"

    info = auth.extra.raw_info.to_h.deep_stringify_keys
    supplied = Array(info["groups"]) + Array(info.dig("realm_access",
      "roles")) + Array(info.dig("resource_access",
        ENV.fetch("OIDC_CLIENT_ID", nil), "roles"))
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
