# frozen_string_literal: true

# Fail-closed environment configuration for the monitoring endpoint.
module ZabbixConfiguration
  def self.enabled?
    ENV.fetch("CCI_ZABBIX_INTEGRATION_ENABLED", "false").casecmp?("true")
  end

  def self.sources
    value = ENV.fetch("CCI_ZABBIX_CERTIFICATE_SOURCES", "consul")
    return %w[consul filesystem] if value == "both"
    return [value] if %w[consul filesystem].include?(value)

    raise ArgumentError, "CCI_ZABBIX_CERTIFICATE_SOURCES must be consul, filesystem or both"
  end

  def self.token
    ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN", "")
  end

  def self.available?
    enabled? && token.present?
  end
end
