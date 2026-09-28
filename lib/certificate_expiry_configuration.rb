# frozen_string_literal: true

# Shared warning period for certificate badges, statistics and searches.
module CertificateExpiryConfiguration
  def self.warning_days(environment = ENV)
    value = environment.fetch("CCI_CERTIFICATE_EXPIRY_WARNING_DAYS", "").to_s.strip
    return 10 if value.empty?
    return value.to_i if value.match?(/\A[0-9]+\z/) && value.to_i.positive?

    raise ArgumentError, "CCI_CERTIFICATE_EXPIRY_WARNING_DAYS must be a positive integer."
  end
end
