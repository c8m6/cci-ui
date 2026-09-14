class CatalogIndexer
  def self.run
    synchronize do
      new.filesystem
      new.consul
    end
  end

  def self.refresh_consul
    synchronize { new.consul }
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
    record = Certificate.find_or_initialize_by(attrs.slice(:area, :source, :source_id))
    record.update!(metadata.merge(attrs).merge(search_text: text, indexed_at: Time.current))
    record
  end

  def filesystem
    return unless ENV.fetch("LEGACY_PATH", Rails.root.join("data").to_s).then { |path| File.directory?(path) }
    area = LegacyStore.area
    raise Certificates::Error, "Ungültiger Bereich für Dateibestand." unless AreaConfiguration.ids.include?(area)
    seen = []
    root = LegacyStore.root
    root.glob("**/*.pem").each do |path|
      relative = path.relative_path_from(root).to_s
      begin
        certificates = LegacyStore.certificates(relative)
        tag_path = relative.sub(/\.pem\z/, ".tag")
        tags = root.join(tag_path).exist? ? [LegacyStore.read(LegacyStore.safe_path(tag_path)).force_encoding("UTF-8").scrub.strip].reject(&:empty?) : []
        has_key = root.join(relative.sub(/\.pem\z/, ".key")).exist? || LegacyStore.read(LegacyStore.safe_path(relative)).include?("PRIVATE KEY-----")
        certificates.each_with_index do |cert, index|
          seen << upsert(cert, area: area, source: "filesystem", source_id: "#{relative}##{index}", tags: tags, has_key: has_key, active: true).id
        end
      rescue Certificates::Error, OpenSSL::OpenSSLError => error
        Rails.logger.warn("Altbestand: Datei übersprungen (#{error.class})")
      end
    end
    Certificate.where(source: "filesystem").where.not(id: seen).delete_all
  end

  def consul
    seen = []
    connection = ConsulStore.client
    AreaConfiguration.ids.each do |area|
      base = ConsulStore.prefix(area)
      lookups = connection.all("#{base}/lookups/").to_h do |item|
        data = JSON.parse(item[:value])
        [data.fetch("entry_id"), data.fetch("active_version")]
      end
      connection.all("#{base}/versions/").each do |item|
        id = item[:key].split("/").last
        data = JSON.parse(item[:value])
        cert = OpenSSL::X509::Certificate.new(data.fetch("pem"))
        seen << upsert(cert, area: area, source: "consul", source_id: id, entry_id: data.fetch("entry_id"),
          lookup: data.fetch("lookup"), tags: JSON.parse(data.fetch("tags")), has_key: data["has_key"] == "1",
          client: data["client"].is_a?(String) ? data["client"].presence : nil,
          created_by: data["created_by"].is_a?(String) ? data["created_by"].presence : nil,
          active: lookups[data.fetch("entry_id")] == id).id
      end
    end
    Certificate.where(source: "consul", area: AreaConfiguration.ids).where.not(id: seen).delete_all
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
