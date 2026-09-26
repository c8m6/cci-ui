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
  after_create_commit :log_business_action
  after_update_commit :log_business_outcome, if: :saved_change_to_details?

  # Commit the intent before changing source material. A timeout or process crash must
  # never erase who requested a change or pretend its result is known.
  def self.record_mutation!(action:, area:, actor:, references:, details:, actor_display_name: nil)
    result = nil
    record_mutations!(events: [{ action: action, area: area, actor: actor,
                                 actor_display_name: actor_display_name, references: references, details: details }]) do
      result = yield
    end
    result
  end

  # One external transaction can affect several areas. Persist one area-scoped
  # audit intent per target before executing it, then give every intent the same outcome.
  def self.record_mutations!(events:)
    records = transaction do
      events.map do |attributes|
        pending_details = attributes.fetch(:details).merge(outcome: "pending")
        create!(**attributes.except(:details), details: pending_details)
      end
    end
    begin
      result = yield
    rescue ConsulConnection::Conflict
      complete_records!(records, "rejected")
      raise
    rescue StandardError
      complete_records!(records, "unknown")
      raise
    end
    complete_records!(records, "succeeded")
    result
  end

  def self.complete_records!(records, outcome)
    transaction do
      records.each do |event|
        event.update!(details: event.details.merge("outcome" => outcome, "finished_at" => Time.current.iso8601(6)))
      end
    end
  end
  private_class_method :complete_records!

  def log_business_action
    OperationalLog.info(logger: "cci.audit", message: "Business action recorded",
      operation: action, audit_event_id: id, area: area, user: actor,
      display_name: actor_display_name, result: details["outcome"])
  end

  def log_business_outcome
    return unless details["outcome"]

    OperationalLog.info(logger: "cci.audit", message: "Business action completed",
      operation: action, audit_event_id: id, area: area, user: actor,
      display_name: actor_display_name, result: details["outcome"])
  end

  def self.snapshot(cert)
    Certificates::Codec.metadata(cert).slice(:common_name, :subject, :issuer, :serial, :fingerprint)
  end

  def self.record_export!(records, entries, identity:, format:, include_key:, include_chain:, filename:)
    occurred_at = Time.current
    # All areas are recorded together before the response can release any bytes.
    transaction do
      records.zip(entries).group_by { |record, _| record.area }.each do |area, pairs|
        create!(actor: identity.uid, actor_display_name: identity.display_name,
          action: include_key ? "export_private" : "export_public", area: area,
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
