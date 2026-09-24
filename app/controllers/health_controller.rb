# frozen_string_literal: true

# Exposes readiness and dependency diagnostics without requiring a signed-in session.
class HealthController < ActionController::Base
  def show
    report(ApplicationHealth.check)
  end

  def ready
    report(ApplicationReadiness.check)
  end

  private

  def report(failures)
    response.headers["Cache-Control"] = "no-store"
    body = { status: failures.empty? ? "ok" : "unavailable" }
    if Rails.application.config.x.show_error_details
      body[:failures] = failures.transform_values { |error| "#{error.class}: #{error.message}" }
    end
    render json: body, status: failures.empty? ? :ok : :service_unavailable
  end
end
