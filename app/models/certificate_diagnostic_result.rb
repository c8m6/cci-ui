# frozen_string_literal: true

# Evidence is independent of the certificate's operational/date status.
class CertificateDiagnosticResult < ApplicationRecord
  def display_state(config, now = Time.current)
    return "disabled" unless config.enabled?(check_id)
    return "pending" unless checked_at
    return "stale" if expires_at && expires_at <= now

    state
  end
end
