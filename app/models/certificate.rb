class Certificate < ApplicationRecord
  validates :area, inclusion: { in: ->(_) { AreaConfiguration.ids } }
  validates :source, inclusion: { in: %w[filesystem consul] }
  validates :rollout_status, inclusion: { in: ConsulStore::ROLLOUT_STATUSES }
  scope :visible_to, ->(identity) { where(area: identity.areas, source: %w[filesystem consul]) }

  def puppetdb_refresh_failed? = puppetdb_error_at.present?

  def status
    I18n.t("ui.#{status_key}")
  end

  def status_key
    return "future" if not_before > Time.current
    return "expired" if not_after <= Time.current
    return "expiring" if not_after < 30.days.from_now
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
