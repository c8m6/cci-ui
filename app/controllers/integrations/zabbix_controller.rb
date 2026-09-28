# frozen_string_literal: true

module Integrations
  # Deliberately independent of interactive authentication, cookies and UI errors.
  class ZabbixController < ActionController::API
    before_action :authenticate_integration
    rescue_from StandardError, with: :integration_unavailable

    def show
      render json: CertificateMonitoring.snapshot
    end

    private

    # Keep this machine endpoint independent of optional interactive error details.
    def integration_unavailable(error)
      OperationalLog.error(logger: "cci.integration", message: "Zabbix inventory unavailable",
        operation: "zabbix_inventory", error_type: error.class.name)
      head :service_unavailable
    end

    def authenticate_integration
      response.headers["Cache-Control"] = "no-store"
      return head :not_found unless ZabbixConfiguration.available?
      return if IntegrationAuthentication.valid_bearer?(request.authorization, ZabbixConfiguration.token)

      response.headers["WWW-Authenticate"] = "Bearer"
      head :unauthorized
    end
  end
end
