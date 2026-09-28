# frozen_string_literal: true

# Exposes readiness and authenticated dependency diagnostics without a signed-in session.
class HealthController < ActionController::Base
  @cache = HealthCheckCache.new

  class << self
    attr_reader :cache
  end

  def show
    response.headers["Cache-Control"] = "no-store"
    expected = ENV.fetch("CCI_HEALTH_TOKEN", nil)
    return head :service_unavailable if expected.blank?

    unless IntegrationAuthentication.valid_bearer?(request.authorization, expected)
      response.headers["WWW-Authenticate"] = "Bearer"
      return head :unauthorized
    end

    failures = self.class.cache.fetch { ApplicationHealth.check }
    return render json: { status: "unavailable" }, status: :service_unavailable unless failures

    report(failures)
  end

  def ready
    report(ApplicationReadiness.check)
  end

  private

  def report(failures)
    failures.each do |service, error|
      OperationalLog.failure(logger: "cci.health", message: "Health check failed", error: error, service: service,
        operation: "health_check", configuration: OperationalLog.configuration(service))
    end
    response.headers["Cache-Control"] = "no-store"
    body = { status: failures.empty? ? "ok" : "unavailable" }
    if Rails.application.config.x.show_error_details
      body[:failures] = failures.transform_values { |error| "#{error.class}: #{error.message}" }
    end
    render json: body, status: failures.empty? ? :ok : :service_unavailable
  end
end
