class CatalogIndexer
  def self.run
    synchronize do
      indexer = new
      failures = []
      %i[filesystem consul puppetdb].each do |source|
        begin
          indexer.public_send(source)
        rescue Certificates::Error, ConsulConnection::Error, PuppetdbConnection::Error => error
          failures << error
        end
      end
      raise failures.first if failures.any?
    end
  end

  def self.refresh_consul
    synchronize { new.consul }
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
    text = [metadata[:subject], metadata[:issuer], metadata[:common_name], *metadata[:sans], *attrs[:tags], attrs[:certid]].compact.join(" ")
    record = Certificate.find_or_initialize_by(attrs.slice(:area, :source, :source_id).merge(fingerprint: metadata.fetch(:fingerprint)))
    record.update!(metadata.merge(attrs).merge(sha1_fingerprint: Digest::SHA1.hexdigest(cert.to_der), search_text: text, indexed_at: Time.current))
    record
  end

  def filesystem
    failures = []
    LegacyStore.areas.each do |area|
      begin
        filesystem_area(area)
      rescue Certificates::Error, ConsulConnection::Error => error
        Rails.logger.warn("Dateibestand #{area}: Indexierung fehlgeschlagen (#{error.class})")
        failures << error
      end
    end
    raise failures.first if failures.any?
  end

  def filesystem_area(area)
    inventory = LegacyStore.inventory(area: area)
    root = LegacyStore.root(area: area)
    inventory.each do |entry|
      relative = entry.fetch(:relative)
      tag_path = relative.sub(/\.pem\z/i, ".tag")
      tags = root.join(tag_path).exist? ? [LegacyStore.read(LegacyStore.safe_path(tag_path, area: area)).force_encoding("UTF-8").scrub.strip].reject(&:empty?) : []
      has_key = root.join(relative.sub(/\.pem\z/i, ".key")).exist? || LegacyStore.read(LegacyStore.safe_path(relative, area: area)).include?("PRIVATE KEY-----")
      entry.fetch(:certificates).each_with_index do |cert, index|
        upsert(cert, area: area, source: "filesystem", source_id: "#{relative}##{index}", tags: tags, has_key: has_key, active: true,
          rollout_status: "active", archived: false)
      end
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
          client: data["client"], created_by: data["created_by"], imported_at: Time.iso8601(data.fetch("created_at")), **state)
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
