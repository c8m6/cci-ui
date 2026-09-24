# frozen_string_literal: true

# Persists mutation intent and outcome separately so uncertain writes stay auditable.
class AuditEvent < ApplicationRecord
  ACTIONS = %w[archive status_change import activate delete export_public export_private csr_create csr_upload csr_publish csr_reveal
    csr_download csr_verify csr_rotate].freeze

  def self.action_label(action)
    ACTIONS.include?(action) ? I18n.t("audit.actions.#{action}") : action
  end

  scope :visible_to, ->(identity) { where(area: identity.audit_areas) }
  before_validation { self.occurred_at ||= Time.current }

  # Commit the intent before changing source material. A timeout or process crash must
  # never erase who requested a change or pretend its result is known.
  def self.record_mutation!(action:, area:, actor:, references:, details:)
    event = create!(action: action, area: area, actor: actor, references: references,
      details: details.merge(outcome: "pending"))
    begin
      result = yield
    rescue ConsulConnection::Conflict
      event.update!(details: event.details.merge("outcome" => "rejected", "finished_at" => Time.current.iso8601(6)))
      raise
    rescue StandardError
      event.update!(details: event.details.merge("outcome" => "unknown", "finished_at" => Time.current.iso8601(6)))
      raise
    end
    event.update!(details: event.details.merge("outcome" => "succeeded", "finished_at" => Time.current.iso8601(6)))
    result
  end

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
                         certid: record.certid, kind: "selected"),
                         *entry[:chain].map do |cert|
                           snapshot(cert).merge(kind: "chain", parent_source_id: record.source_id)
                         end]
                     end })
      end
    end
  end
end
