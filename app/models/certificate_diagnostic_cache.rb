# frozen_string_literal: true

# Durable shared evidence and a fenced, expiring indexer-phase lease.
class CertificateDiagnosticCache < ApplicationRecord
  def self.acquire(key, seconds:)
    create_or_find_by!(cache_id: key)
    token = SecureRandom.uuid
    claimed = where(cache_id: key).where("lease_until IS NULL OR lease_until < ?", Time.current)
                                  .update_all(lease_token: token, lease_until: Time.current + seconds)
    token if claimed == 1
  end

  def self.release(key, token)
    where(cache_id: key, lease_token: token).update_all(lease_token: nil, lease_until: nil)
  end
end
