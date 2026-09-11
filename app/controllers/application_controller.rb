class ApplicationController < ActionController::Base
  before_action :require_identity
  before_action :private_response
  helper_method :current_identity
  rescue_from Certificates::Error do |error|
    redirect_back fallback_location: root_path, alert: error.message, status: :see_other
  end
  rescue_from ConsulConnection::Error do
    render plain: "Der Zertifikatsspeicher ist derzeit nicht erreichbar. Bitte später erneut versuchen.", status: :service_unavailable
  end

  def current_identity
    data = session[:identity]
    return unless data && session[:authenticated_at].to_i > 1.hour.ago.to_i
    @current_identity ||= Identity.new(name: data["name"], roles: data["roles"])
  end

  private
  def require_identity
    redirect_to login_path unless current_identity
  end
  def private_response
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Referrer-Policy"] = "same-origin"
  end
  def require_writer!(area)
    raise Certificates::Error, "Für diese Aktion ist die Writer-Rolle im Bereich #{AreaConfiguration.label(area)} erforderlich." unless current_identity.writer?(area)
  end
end
