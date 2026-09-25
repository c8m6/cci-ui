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
    unless request.env["action_dispatch.exception"].equal?(exception) && exception
      fields = { http_method: request.request_method, endpoint: request.path, http_status: @error_status }
      if exception
        OperationalLog.failure(logger: "cci.http", message: "HTTP request failed", error: exception,
          level: @error_status >= 500 ? :error : :warn, **fields)
      else
        OperationalLog.warn(logger: "cci.http", message: "HTTP error response", **fields)
      end
    end
    # ShowExceptions rewrites even HEAD requests to GET before dispatching here.
    if request.head? || request.env["action_dispatch.original_request_method"] == "HEAD"
      return head @error_status, content_type: "text/html"
    end

    render template: "errors/show", layout: "application", formats: [:html], status: @error_status
  end
end
