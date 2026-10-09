# frozen_string_literal: true

# Refreshes source projections under a shared lock, preserving data on failed scans.
class CatalogIndexer
  def self.run
    context = LogContext.correlation_id ? {} : { correlation_id: SecureRandom.uuid }
    LogContext.with(**context) do
      synchronize do
        indexer = new
        failures = []
        %i[filesystem consul ca_inventory puppetdb].each do |source|
          if source == :ca_inventory && failures.any?
            CaInventoryRefresh.failed!
            next
          end
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          OperationalLog.debug(logger: "cci.indexer", message: "Index source refresh started",
            operation: "refresh_index_source", source: source)
          indexer.public_send(source)
          OperationalLog.debug(logger: "cci.indexer", message: "Index source refresh completed",
            operation: "refresh_index_source", source: source, result: "succeeded",
            duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1))
        rescue Certificates::Error, ConsulConnection::Error, PuppetdbConnection::Error => e
          OperationalLog.failure(logger: "cci.indexer", message: "Index source refresh failed",
            error: e, level: :warn, operation: "refresh_index_source", source: source, result: "failed")
          failures << e
        end
        raise failures.first if failures.any?
      end
    end
  end

  def self.refresh_consul
    synchronize { new.consul }
  end

  def ca_inventory
    CaInventoryRefresh.run
  end

  def puppetdb
    PuppetdbInventory.refresh
  end

  def self.synchronize
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.execute("SELECT pg_advisory_lock(81420911)")
      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(81420911)")
      end
    end
  end

  def upsert(cert, attrs)
    metadata = Certificates::Codec.metadata(cert)
    text = [metadata[:subject], metadata[:issuer], metadata[:common_name], *metadata[:sans], *attrs[:tags],
      attrs[:certid]].compact.join(" ")
    record = Certificate.find_or_initialize_by(attrs.slice(:area, :source,
      :source_id).merge(fingerprint: metadata.fetch(:fingerprint)))
    return record if record.deleted_at

    record.update!(metadata.merge(attrs).merge(sha1_fingerprint: Digest::SHA1.hexdigest(cert.to_der),
      search_text: text, indexed_at: Time.current))
    record
  end

  def filesystem
    failures = []
    log_unassigned_filesystem_records(Certificate.retained.where(source: "filesystem").where.not(area: LegacyStore.areas))
    LegacyStore.areas.each do |area|
      filesystem_area(area)
    rescue Certificates::Error, ConsulConnection::Error => e
      OperationalLog.failure(logger: "cci.indexer", message: "Filesystem scan incomplete; reconciliation skipped",
        error: e, operation: "refresh_filesystem_inventory", area: area)
      failures << e
    end
    raise failures.first if failures.any?
  end

  def filesystem_area(area, approval: nil)
    # Even direct source refreshes must serialize the scan, not just cleanup.
    self.class.synchronize do
      root = LegacyStore.root(area: area)
      previous = Certificate.retained.where(area: area, source: "filesystem", filesystem_source_path: root.to_s).to_a
      inventory = filesystem_inventory(area, root)
      reconciliation = nil
      Certificate.transaction do
        found = inventory.flat_map do |entry|
          entry.fetch(:certificates).each_with_index.map do |cert, index|
            upsert(cert, area: area, source: "filesystem", source_id: "#{entry.fetch(:relative)}##{index}",
              tags: entry.fetch(:tags), has_key: entry.fetch(:has_key), active: true, rollout_status: "active", archived: false,
              filesystem_source_path: root.to_s, filesystem_missing_scans: 0, filesystem_cleanup_blocked: false).id
          end
        end
        reconciliation = FilesystemReconciliation.new(area: area, source_path: root.to_s, previous_records: previous, found_ids: found)
        reconciliation.call(approval: approval)
      end
      unassigned = Certificate.retained.where(area: area, source: "filesystem")
                              .where("filesystem_source_path IS DISTINCT FROM ?", root.to_s)
      log_unassigned_filesystem_records(unassigned)
      reconciliation.log_result
    end
  rescue SystemCallError, IOError, Timeout::Error => e
    raise Certificates::Error, "Filesystem scan incomplete (#{e.class.name}); reconciliation skipped."
  end

  def filesystem_inventory(area, root)
    inventory = LegacyStore.inventory(area: area) do |entries|
      entries.each do |entry|
        relative = entry.fetch(:relative)
        tag_path = relative.sub(/\.pem\z/i, ".tag")
        tags = if LegacyStore.optional_file?(root.join(tag_path))
                 [LegacyStore.read(LegacyStore.safe_path(tag_path,
                   area: area)).force_encoding("UTF-8").scrub.strip].reject(&:empty?)
               else
                 []
               end
        data = LegacyStore.read(LegacyStore.safe_path(relative, area: area))
        LegacyStore.verify_state!(LegacyStore.safe_path(relative, area: area), entry.fetch(:state))
        if entry.fetch(:certificates).empty?
          raise Certificates::Error, "PEM inventory file contains no certificates; reconciliation skipped."
        end

        has_key = LegacyStore.optional_file?(root.join(relative.sub(/\.pem\z/i, ".key"))) || data.include?("PRIVATE KEY-----")
        entry.merge!(tags: tags, has_key: has_key)
      end
    end
    raise Certificates::Error, "Filesystem source changed during scan." unless root == LegacyStore.root(area: area)

    inventory
  end

  def log_unassigned_filesystem_records(records)
    records.group(:area, :filesystem_source_path).count.each do |(area, source_path), count|
      OperationalLog.warn(logger: "cci.indexer", message: "Filesystem records retained without a matching configured source",
        operation: "reconcile_filesystem", source: "filesystem", area: area, source_path: source_path, retained_count: count)
    end
  end

  def consul
    connection = ConsulStore.client
    AreaConfiguration.ids.each do |area|
      base = ConsulStore.prefix(area)
      certids = connection.all("#{base}/certids/").to_h do |item|
        [item.fetch(:key).delete_prefix("#{base}/certids/"), JSON.parse(item.fetch(:value))]
      end
      connection.all("#{base}/certs/").each do |item|
        id = item.fetch(:key).delete_prefix("#{base}/certs/")
        certid, version = ConsulStore.split_id(id)
        data = JSON.parse(item.fetch(:value))
        cert = OpenSSL::X509::Certificate.new(data.fetch("pem"))
        entry = certids[certid]
        next unless entry

        state = ConsulStore.catalog_status(entry).merge(active: entry.fetch("active_version") == version)
        upsert(cert, area: area, source: "consul", source_id: id,
          certid: certid, certificate_version: version, tags: data.fetch("tags"), has_key: data.fetch("has_key"),
          client: CertificateProvenance.catalog_client(data["client"]), created_by: data["created_by"],
          imported_at: Time.iso8601(data.fetch("created_at")), **state)
      end
      certids.each do |certid, entry|
        records = Certificate.where(source: "consul", area: area, certid: certid)
        records.update_all(ConsulStore.catalog_status(entry))
        records.where.not(certificate_version: entry.fetch("active_version")).update_all(active: false)
      end
    end
    ImportDraft.where("expires_at < ?", Time.current).delete_all
  end
end
