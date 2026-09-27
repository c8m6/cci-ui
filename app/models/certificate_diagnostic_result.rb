# frozen_string_literal: true

# Evidence is independent of the certificate's operational/date status.
class CertificateDiagnosticResult < ApplicationRecord
  def display_state(config, now = Time.current)
    return "disabled" unless config.enabled?(check_id)
    return "pending" unless checked_at
    return "stale" if expires_at && expires_at <= now
    return "stale" if details["configuration"] && details["configuration"] != config.version(check_id)

    return "stale" if outdated_profile?(config)

    combined_state(config, now)
  end

  private

  def outdated_profile?(config)
    data_version && config.trust.profiles.key?(check_id) && data_version != CertificateDiagnostics::Profiles.version(check_id, config)
  end

  def combined_state(config, now)
    if check_id == "trust_chrome" && state == "good" && config.enabled?("chrome_policy")
      policy = self.class.find_by(area: area, fingerprint: fingerprint, check_id: "chrome_policy")
      return policy&.display_state(config, now) || "pending"
    end

    state
  end
end
