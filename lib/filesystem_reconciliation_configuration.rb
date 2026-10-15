# frozen_string_literal: true

require_relative "cci_configuration"

# Validated limits for source-scoped filesystem reconciliation.
class FilesystemReconciliationConfiguration
  def self.configuration = CciConfiguration.current.dig("certificates", "reconciliation")
end
