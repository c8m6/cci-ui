# frozen_string_literal: true

# Reconciles one complete inventory inside the indexer's lock and transaction.
class FilesystemReconciliation
  def initialize(area:, source_path:, previous_records:, found_ids:)
    @area = area
    @source_path = source_path
    @previous_records = previous_records
    @found_ids = found_ids.to_set
    @settings = FilesystemReconciliationConfiguration.configuration
    @events = []
  end

  # Administrator-only runner entry point: fresh scan, exact IDs, named actor.
  # Approval applies to this invocation, never to subsequent scheduled passes.
  def self.approve!(area:, certificate_ids:, actor:)
    unless actor.is_a?(String) && !actor.strip.empty? && certificate_ids.is_a?(Array) &&
           certificate_ids.any? && certificate_ids.all? { |id| id.is_a?(Integer) && id.positive? } &&
           certificate_ids.uniq.size == certificate_ids.size
      raise ArgumentError, "Supply a named actor and a nonempty array of unique positive certificate IDs."
    end

    CatalogIndexer.new.filesystem_area(area, approval: { ids: certificate_ids.sort, actor: actor })
  end

  def call(approval: nil)
    unless @settings.fetch("enabled")
      raise ArgumentError, "Filesystem reconciliation is disabled." if approval

      return
    end

    missing = @previous_records.reject { |record| @found_ids.include?(record.id) }
    threshold = @settings.fetch("missing_after_scans")
    # Approval must refer to records already confirmed before the fresh scan.
    validate_approval!(approval, missing, threshold) if approval
    missing.each { |record| mark_missing(record, threshold) }
    candidates = missing.select { |record| record.filesystem_missing_scans >= threshold }
    validate_approval!(approval, candidates, threshold) if approval
    return if candidates.empty?

    percent = candidates.size * 100.0 / @previous_records.size
    if !approval && deletion_blocked?(candidates)
      Certificate.where(id: candidates.map(&:id)).update_all(filesystem_cleanup_blocked: true)
      @events << [:warn, "Filesystem reconciliation suspended by deletion limit",
        { candidates: candidates.size, previous_count: @previous_records.size, delete_percent: percent,
          max_delete_percent: @settings.fetch("max_delete_percent"), approval_required: true }]
      return
    end

    remove(candidates, percent, approval)
  end

  # Emit success messages only after the outer source transaction has committed.
  def log_result
    @events.each do |level, message, fields|
      OperationalLog.public_send(level, logger: "cci.indexer", message: message,
        operation: "reconcile_filesystem", area: @area, source: "filesystem", source_path: @source_path, **fields)
    end
  end

  private

  def deletion_blocked?(candidates)
    candidates.any?(&:filesystem_cleanup_blocked) ||
      candidates.size * 100 > @settings.fetch("max_delete_percent") * @previous_records.size
  end

  def validate_approval!(approval, missing, threshold)
    confirmed_ids = missing.select { |record| record.filesystem_missing_scans >= threshold }.map(&:id).sort
    return if confirmed_ids == approval.fetch(:ids)

    raise ArgumentError, "Confirmed missing certificates changed; review the source and exact IDs again."
  end

  def mark_missing(record, threshold)
    count = [record.filesystem_missing_scans + 1, threshold].min
    return if count == record.filesystem_missing_scans

    record.update!(filesystem_missing_scans: count)
    @events << [:info, "Filesystem certificate missing; reconciliation pending",
      { certificate_id: record.id, source_id: record.source_id, missing_scans: count }]
  end

  def remove(candidates, percent, approval)
    details = { operation: "filesystem_reconciliation", source: "filesystem", source_path: @source_path,
                outcome: "succeeded", approved: !approval.nil?, delete_percent: percent, previous_count: @previous_records.size,
                max_delete_percent: @settings.fetch("max_delete_percent"), certificates: candidates.map do |record|
                  record.attributes.slice("id", "source_id", "fingerprint", "common_name", "subject", "issuer", "serial")
                end }
    AuditEvent.create!(action: "delete", area: @area, actor: approval ? approval.fetch(:actor) : "indexer",
      references: candidates.map(&:source_id), details: details)
    candidates.each do |record|
      record.destroy!
      @events << [:info, "Stale filesystem certificate catalog record removed",
        { certificate_id: record.id, source_id: record.source_id }]
    end
    CaInventory.where(area: @area).update_all(authorities: [], issues: [], checked_at: nil)
  end
end
