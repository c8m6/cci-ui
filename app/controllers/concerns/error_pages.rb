# frozen_string_literal: true

# Renders localised error pages without exposing exception details by default.
module ErrorPages
  private

  def render_error(status, exception: nil, message: nil)
    @error_status = Rack::Utils.status_code(status)
    @error_title = I18n.t("errors.pages.status_#{@error_status}.title", default: I18n.t("errors.pages.generic.title"))
    @error_message = message || I18n.t("errors.pages.status_#{@error_status}.message",
      default: I18n.t("errors.pages.generic.message"))
    if exception && Rails.application.config.x.show_error_details
      @error_details = exception.full_message(highlight: false,
        order: :top)
    end
    # Unhandled exceptions have already been logged by Rails' DebugExceptions.
    unless request.env["action_dispatch.exception"].equal?(exception) && exception
      detail = exception ? exception.full_message(highlight: false) : @error_title
      Rails.logger.error("[#{request.request_id}] HTTP #{@error_status}: #{detail}")
    end
    # ShowExceptions rewrites even HEAD requests to GET before dispatching here.
    if request.head? || request.env["action_dispatch.original_request_method"] == "HEAD"
      return head @error_status, content_type: "text/html"
    end

    render template: "errors/show", layout: "application", formats: [:html], status: @error_status
  end
end
