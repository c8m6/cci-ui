class AuditEvent < ApplicationRecord
  ACTIONS = %w[archive status_change import activate delete export_public export_private].freeze

  def self.action_label(action)
    ACTIONS.include?(action) ? I18n.t("audit.actions.#{action}") : action
  end

  scope :visible_to, ->(identity) { where(area: identity.audit_areas) }
  before_validation { self.occurred_at ||= Time.current }

  def self.snapshot(cert)
    Certificates::Codec.metadata(cert).slice(:common_name, :subject, :issuer, :serial, :fingerprint)
  end

  def self.record_export!(records, entries, identity:, format:, include_key:, include_chain:, filename:)
    occurred_at = Time.current
    # All areas are recorded together before the response can release any bytes.
    transaction do
      records.zip(entries).group_by { |record, _| record.area }.each do |area, pairs|
        create!(actor: identity.name, action: include_key ? "export_private" : "export_public", area: area,
          occurred_at: occurred_at, references: pairs.map { |record, _| record.source_id },
          details: { format: format, filename: filename, include_key: include_key, include_chain: include_chain,
            certificates: pairs.flat_map do |record, entry|
              [snapshot(entry[:certificate]).merge(source: record.source, source_id: record.source_id,
                lookup: record.lookup, kind: "selected"),
                *entry[:chain].map { |cert| snapshot(cert).merge(kind: "chain", parent_source_id: record.source_id) }]
            end })
      end
    end
  end
end
