# frozen_string_literal: true

# Exposes dependency readiness without requiring a signed-in session.
class HealthController < ActionController::Base
  def show
    failures = ApplicationHealth.check
    response.headers["Cache-Control"] = "no-store"
    body = { status: failures.empty? ? "ok" : "unavailable" }
    if Rails.application.config.x.show_error_details
      body[:failures] = failures.transform_values { |error| "#{error.class}: #{error.message}" }
    end
    render json: body, status: failures.empty? ? :ok : :service_unavailable
  end
end
