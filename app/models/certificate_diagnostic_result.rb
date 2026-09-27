# frozen_string_literal: true

# Evidence is independent of the certificate's operational/date status.
class CertificateDiagnosticResult < ApplicationRecord
  def display_state(config, now = Time.current)
    return "disabled" unless config.enabled?(check_id)
    return "pending" unless checked_at
    return "stale" if expires_at && expires_at <= now
    return "stale" if details["configuration"] && details["configuration"] != config.version(check_id)

    return "stale" if data_version && check_id.start_with?("trust_") && data_version != CertificateDiagnostics::Profiles.version(check_id,
      config)

    state
  end
end
