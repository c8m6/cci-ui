# frozen_string_literal: true

# Searchable projection of source material, never the authority for private keys.
class Certificate < ApplicationRecord
  validates :area, inclusion: { in: ->(_) { AreaConfiguration.ids } }
  validates :source, inclusion: { in: %w[filesystem consul] }
  validates :rollout_status, inclusion: { in: ConsulStore::ROLLOUT_STATUSES }
  validate :current_client_reference
  scope :retained, -> { where(deleted_at: nil) }
  scope :visible_to, ->(identity) { retained.where(area: identity.areas, source: %w[filesystem consul]) }

  # Provenance is the existing lifecycle signal supplied by certificate writers.
  def renewal_mode
    return "puppet" if client.to_s.downcase.include?("puppet")

    "manual"
  end

  def current_client_reference
    errors.add(:client, "must use puppet instead of an ACME reference") if CertificateProvenance.obsolete_client?(client)
  end

  def puppetdb_refresh_failed? = puppetdb_error_at.present?

  def require_retained!
    raise Certificates::Error, I18n.t("errors.app.deletion_changed") if deleted_at
  end

  def status
    I18n.t("ui.#{status_key}")
  end

  def status_key
    return "future" if not_before > Time.current
    return "expired" if not_after <= Time.current
    return "expiring" if not_after < CertificateExpiryConfiguration.warning_days.days.from_now

    "valid"
  end

  def status_class
    { "future" => "neutral", "expired" => "danger", "expiring" => "warning", "valid" => "success" }.fetch(status_key)
  end

  def source_label = source == "consul" ? "Consul" : I18n.t("ui.filesystem")

  def origin_label
    return I18n.t("ui.filesystem") if source == "filesystem"
    return I18n.t("ui.unknown_client") if client.blank?

    client == "cci-ui" ? I18n.t("ui.upload_origin") : I18n.t("ui.external_client", client: client)
  end
end
