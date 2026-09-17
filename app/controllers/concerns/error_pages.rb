module ErrorPages
  private

  def render_error(status, exception: nil, message: nil)
    @error_status = Rack::Utils.status_code(status)
    @error_title = I18n.t("errors.pages.status_#{@error_status}.title", default: I18n.t("errors.pages.generic.title"))
    @error_message = message || I18n.t("errors.pages.status_#{@error_status}.message", default: I18n.t("errors.pages.generic.message"))
    @error_details = exception.full_message(highlight: false, order: :top) if exception && Rails.application.config.x.show_error_details
    # Unhandled exceptions have already been logged by Rails' DebugExceptions.
    unless request.env["action_dispatch.exception"].equal?(exception) && exception
      Rails.logger.error("[#{request.request_id}] HTTP #{@error_status}: #{exception ? exception.full_message(highlight: false) : @error_title}")
    end
    render template: "errors/show", layout: "application", formats: [:html], status: @error_status
  end
end
