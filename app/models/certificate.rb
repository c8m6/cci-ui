class Certificate < ApplicationRecord
  validates :area, inclusion: { in: ->(_) { AreaConfiguration.ids } }
  validates :source, inclusion: { in: %w[filesystem consul] }
  validates :rollout_status, inclusion: { in: ConsulStore::ROLLOUT_STATUSES }
  scope :visible_to, ->(identity) { where(area: identity.areas, source: %w[filesystem consul]) }

  def puppetdb_refresh_failed? = puppetdb_error_at.present?

  def status
    return "Noch nicht gültig" if not_before > Time.current
    return "Abgelaufen" if not_after <= Time.current
    return "Läuft bald ab" if not_after < 30.days.from_now
    "Gültig"
  end

  def status_class
    { "Noch nicht gültig" => "neutral", "Abgelaufen" => "danger", "Läuft bald ab" => "warning", "Gültig" => "success" }.fetch(status)
  end

  def source_label = source == "consul" ? "Consul" : "Dateibestand"

  def origin_label
    return "Dateibestand" if source == "filesystem"
    return "Unbekannt (keine Client-Angabe)" if client.blank?
    client == "cci-ui" ? "CCI-UI (Upload)" : "Externer Client: #{client}"
  end
end
