# frozen_string_literal: true

# Fail at boot on invalid configuration instead of starting with partial access.
require_relative "../../lib/area_configuration"
require_relative "../../lib/certificate_area_configuration"
require_relative "../../lib/filesystem_reconciliation_configuration"
AreaConfiguration.configuration
CertificateAreaConfiguration.mode
require_relative "../../lib/consul_tokens"
ConsulTokens.mapping(ENV, areas: AreaConfiguration.ids)
FilesystemReconciliationConfiguration.configuration
