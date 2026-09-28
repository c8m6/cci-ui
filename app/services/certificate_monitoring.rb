# frozen_string_literal: true

# Public metadata only. Historical and retired versions are not live inventory.
module CertificateMonitoring
  def self.snapshot
    records = Certificate.retained.where(area: AreaConfiguration.ids, active: true, archived: false)
                         .where.not(rollout_status: "delete")
                         .select(:id, :common_name, :issuer, :serial, :not_before, :not_after, :client, :created_by)
    { version: 1, generated_at: Time.current.to_i, certificates: records.order(:id).map { |record| serialize(record) } }
  end

  def self.serialize(record)
    { id: record.id, common_name: record.common_name, issuer: record.issuer, serial_number: record.serial,
      valid_from: record.not_before.to_i, valid_until: record.not_after.to_i, renewal: record.renewal_mode }
  end
end
