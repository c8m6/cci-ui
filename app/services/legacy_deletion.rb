# frozen_string_literal: true

require "fiddle/import"

# Retires a complete legacy file bundle under the catalogue's shared lock.
class LegacyDeletion
  # Use Linux no-replace renames rather than a check followed by an overwriting rename.
  module Native
    extend Fiddle::Importer

    dlload Fiddle::Handle::DEFAULT
    extern "int renameat2(int, const char*, int, const char*, unsigned int)"
  end

  def initialize(record)
    @record = record
  end

  def preview
    CatalogIndexer.synchronize do
      files = plan
      { files: files.keys, count: LegacyStore.certificates(relative, area: @record.area).size,
        token: verifier.generate([@record.id, files].to_json, expires_in: 15.minutes) }
    end
  end

  def call(token:, actor:)
    CatalogIndexer.synchronize do
      files = plan
      expected = verifier.verified(token.to_s)
      raise Certificates::Error, I18n.t("errors.app.deletion_changed") unless expected == [@record.id, files].to_json

      records = Certificate.where(area: @record.area, source: "filesystem").select do |record|
        record.source_id.rpartition("#").first == relative
      end
      AuditEvent.record_mutation!(action: "delete", area: @record.area, actor: actor,
        references: records.map(&:source_id), details: audit_details(records, files)) do
        retire(records, files)
      end
    end
  rescue SystemCallError
    raise Certificates::Error, I18n.t("errors.app.deletion_failed")
  end

  private

  def relative = @record.source_id.rpartition("#").first
  def verifier = Rails.application.message_verifier("legacy-deletion")

  def plan
    @record.reload
    unless @record.source == "filesystem" && @record.deleted_at.nil? && relative.match?(/\.pem\z/i)
      raise Certificates::Error, I18n.t("errors.app.deletion_changed")
    end

    base = LegacyStore.root(area: @record.area)
    separate_root!(base)
    names = [relative.sub(/\.pem\z/i, ".key"), relative.sub(/\.pem\z/i, ".tag"), relative]
    files = names.filter_map do |name|
      path = base.join(name)
      next if name != relative && !path.exist? && !path.symlink?

      [name, file_state(base, name)]
    end.to_h
    CertificateMaterial.load(@record)
    files
  rescue SystemCallError
    raise Certificates::Error, I18n.t("errors.app.deletion_failed")
  end

  def file_state(base, name)
    path = base.join(name)
    # Reject aliases, traversal, directory symlinks and non-regular files.
    resolved = LegacyStore.safe_path(name, area: @record.area)
    unless resolved == path && !path.symlink? && path.file? && path.stat.nlink == 1
      raise Certificates::Error, I18n.t("errors.app.deletion_unsafe")
    end

    target = Pathname.new("#{path}.DELETED")
    raise Certificates::Error, I18n.t("errors.app.deletion_collision") if target.exist? || target.symlink?

    stat = path.stat
    [stat.dev, stat.ino, stat.size, stat.mtime.to_r.to_s, stat.ctime.to_r.to_s]
  end

  def separate_root!(base)
    LegacyStore.areas.excluding(@record.area).each do |area|
      other = LegacyStore.root(area: area)
      next unless base == other || base.to_s.start_with?("#{other}/") || other.to_s.start_with?("#{base}/")

      raise Certificates::Error, I18n.t("errors.app.deletion_unsafe")
    end
  end

  def audit_details(records, files)
    { source: "filesystem", operation: "rename", files: files.keys.to_h { |name| [name, "#{name}.DELETED"] },
      certificates: records.map do |record|
        record.attributes.slice("common_name", "subject", "issuer", "serial", "fingerprint", "source", "source_id")
      end }
  end

  def retire(records, files)
    moved = []
    begin
      Certificate.transaction do
        files.each_key do |name|
          path = LegacyStore.safe_path(name, area: @record.area).to_s
          move(path, "#{path}.DELETED")
          moved << path
        end
        Certificate.where(id: records.map(&:id)).update_all(deleted_at: Time.current, active: false)
        # Invalidate cached links and exports immediately; the next scan rebuilds them.
        CaInventory.where(area: @record.area).update_all(authorities: [], issues: [], checked_at: nil)
      end
    rescue StandardError
      moved.reverse_each { |path| move("#{path}.DELETED", path) }
      raise
    end
  end

  # Linux RENAME_NOREPLACE keeps existing backups intact, even during a race.
  def move(source, target)
    result = Native.renameat2(-100, source, -100, target, 1)
    raise SystemCallError.new("renameat2", Fiddle.last_error) unless result.zero?
  end
end
