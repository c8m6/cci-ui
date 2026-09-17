module WebContext
  extend ActiveSupport::Concern

  included do
    around_action :with_locale
    before_action :private_response
    helper_method :current_identity
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

  def private_response
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Referrer-Policy"] = "same-origin"
  end
end
