class ApplicationController < ActionController::Base
  around_action :with_locale
  before_action :require_identity
  before_action :private_response
  helper_method :current_identity
  rescue_from Certificates::Error do |error|
    redirect_back fallback_location: root_path, alert: error.message, status: :see_other
  end
  rescue_from ConsulConnection::Error do
    # Exception handlers run outside the action's around callback.
    with_locale do
      render plain: I18n.t("errors.app.store_unavailable"), status: :service_unavailable
    end
  end

  def current_identity
    data = session[:identity]
    return unless data && session[:authenticated_at].to_i > 1.hour.ago.to_i
    @current_identity ||= Identity.new(name: data["name"], roles: data["roles"])
  end

  private
  def with_locale(&action)
    locale = cookies.signed[:locale]
    locale = BrowserLocale.resolve(request.headers["Accept-Language"]) unless I18n.available_locales.map(&:to_s).include?(locale)
    I18n.with_locale(locale) do
      response.headers["Content-Language"] = I18n.locale.to_s
      action.call
    end
  end

  def require_identity
    redirect_to login_path unless current_identity
  end
  def private_response
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Referrer-Policy"] = "same-origin"
  end
  def require_writer!(area)
    raise Certificates::Error, I18n.t("errors.app.writer_required", area: AreaConfiguration.label(area)) unless current_identity.writer?(area)
  end
end
