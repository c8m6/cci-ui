# frozen_string_literal: true

require_relative "cci_configuration"

# Shared warning period for certificate badges, statistics and searches.
module CertificateExpiryConfiguration
  def self.warning_days = CciConfiguration.current.dig("certificates", "expiry_warning_days")
end
