# frozen_string_literal: true

# Authenticates requests and applies area-specific permissions before actions run.
class ApplicationController < ActionController::Base
  include WebContext
  include ErrorPages

  before_action :require_dependencies
  before_action :require_identity
  rescue_from Certificates::Error do |error|
    Rails.logger.error(error.full_message(highlight: false))
    redirect_back fallback_location: root_path, alert: error.message, status: :see_other
  end

  private

  def require_dependencies
    failures = ApplicationHealth.check
    return if failures.empty?

    details = failures.map { |name, error| "#{name}: #{error.full_message(highlight: false)}" }.join("\n")
    render_error(:service_unavailable, exception: ApplicationHealth::Unavailable.new(details))
  end

  def require_identity
    redirect_to login_path unless current_identity
  end

  def require_writer!(area)
    return if current_identity.writer?(area)

    raise Certificates::Error,
      I18n.t("errors.app.writer_required",
        area: AreaConfiguration.label(area))
  end
end
