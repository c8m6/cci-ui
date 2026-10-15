# frozen_string_literal: true

require_relative "cci_configuration"

# Fail-closed access to startup-validated monitoring settings.
module ZabbixConfiguration
  def self.enabled? = CciConfiguration.current.dig("integrations", "zabbix", "enabled")
  def self.token = CciConfiguration.current.dig("integrations", "zabbix", "token")

  def self.sources
    value = CciConfiguration.current.dig("integrations", "zabbix", "certificate_sources")
    value == "both" ? %w[consul filesystem] : [value]
  end

  def self.available? = enabled? && token.present?
end
