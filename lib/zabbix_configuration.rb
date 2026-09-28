# frozen_string_literal: true

# Fail-closed environment configuration for the monitoring endpoint.
module ZabbixConfiguration
  def self.enabled?
    ENV.fetch("CCI_ZABBIX_INTEGRATION_ENABLED", "false").casecmp?("true")
  end

  def self.token
    ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN", "")
  end

  def self.available?
    enabled? && token.present?
  end
end
