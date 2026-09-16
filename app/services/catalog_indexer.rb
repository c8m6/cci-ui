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
    text = [metadata[:subject], metadata[:issuer], metadata[:common_name], *metadata[:sans], *attrs[:tags], attrs[:lookup]].compact.join(" ")
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
      lookups = connection.all("#{base}/lookups/").to_h do |item|
        data = JSON.parse(item[:value])
        [data.fetch("entry_id"), data]
      end
      connection.all("#{base}/versions/").each do |item|
        id = item[:key].split("/").last
        data = JSON.parse(item[:value])
        cert = OpenSSL::X509::Certificate.new(data.fetch("pem"))
        lookup = lookups[data.fetch("entry_id")]
        state = lookup ? ConsulStore.catalog_status(lookup).merge(active: lookup["active_version"] == id) : {}
        upsert(cert, area: area, source: "consul", source_id: id, entry_id: data.fetch("entry_id"),
          lookup: data.fetch("lookup"), tags: JSON.parse(data.fetch("tags")), has_key: data["has_key"] == "1",
          client: data["client"].is_a?(String) ? data["client"].presence : nil,
          created_by: data["created_by"].is_a?(String) ? data["created_by"].presence : nil,
          **state)
      end
      # Retained versions may no longer exist in the source, but lookup-wide
      # status and archiving still apply to their catalog records.
      lookups.each do |entry_id, lookup|
        records = Certificate.where(source: "consul", area: area, entry_id: entry_id)
        records.update_all(ConsulStore.catalog_status(lookup))
        records.where.not(source_id: lookup["active_version"]).update_all(active: false)
      end
    end
    connection.all("#{ConsulStore.namespace}/events/").each do |item|
      fields = JSON.parse(item[:value])
      AuditEvent.find_or_create_by!(store_event_id: item[:key]) do |event|
        event.actor = fields.fetch("actor")
        event.action = fields.fetch("action")
        event.area = fields.fetch("area")
        event.references = [fields.fetch("id")]
        event.occurred_at = Time.iso8601(fields.fetch("at"))
        event.details = fields.fetch("details", {})
      end
    end
    ImportDraft.where("expires_at < ?", Time.current).delete_all
  end
end
