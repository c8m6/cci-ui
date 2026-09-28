# frozen_string_literal: true

require "zabbix_configuration"

if ZabbixConfiguration.enabled? && !ZabbixConfiguration.available?
  OperationalLog.error(logger: "cci.configuration",
    message: "Zabbix integration unavailable: CCI_ZABBIX_INTEGRATION_TOKEN is missing",
    operation: "configure_zabbix", result: "disabled")
end
