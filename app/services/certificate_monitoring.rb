# frozen_string_literal: true

# Public metadata only. Historical and retired versions are not live inventory.
module CertificateMonitoring
  def self.snapshot
    records = Certificate.retained.where(area: AreaConfiguration.ids, active: true, archived: false)
                         .where(source: ZabbixConfiguration.sources).where.not(rollout_status: "delete")
                         .select(:id, :source, :fingerprint, :common_name, :issuer, :serial, :not_before, :not_after, :client, :created_by)
    # Fingerprints identify identical DER material across areas and paths. Keep
    # single-source behavior, but prefer Consul and then the oldest ID in both mode.
    records = records.order(:id).to_a
    if ZabbixConfiguration.sources.length == 2
      records = records.sort_by { |record| [record.source == "consul" ? 0 : 1, record.id] }
                       .uniq(&:fingerprint).sort_by(&:id)
    end
    { version: 1, generated_at: Time.current.to_i, certificates: records.map { |record| serialize(record) } }
  end

  def self.serialize(record)
    { id: record.id, common_name: record.common_name, issuer: record.issuer, serial_number: record.serial,
      valid_from: record.not_before.to_i, valid_until: record.not_after.to_i, renewal: record.renewal_mode }
  end
end
