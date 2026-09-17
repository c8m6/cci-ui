class ConsulStore
  ROLLOUT_STATUSES = %w[active norollout delete].freeze

  def self.rollout_status(entry)
    status = entry.fetch("status", "active")
    raise Certificates::Error, I18n.t("errors.app.stored_status") unless ROLLOUT_STATUSES.include?(status)
    status
  end

  def self.validate_lookup!(lookup)
    raise Certificates::Error, I18n.t("errors.app.lookup_format") unless lookup.is_a?(String) && lookup.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
  end

  def self.lookup_snapshot(area, lookup)
    validate_lookup!(lookup)
    client.get("#{prefix(area)}/lookups/#{lookup}")
  end
  def self.status_snapshot(record)
    lookup_snapshot(record.area, record.lookup) if record.source == "consul"
  end

  def self.catalog_status(entry)
    archived = entry.fetch("archived", false)
    unless archived == true || archived == false
      raise Certificates::Error, I18n.t("errors.app.stored_archive")
    end
    status = rollout_status(entry)
    if archived && status != "delete"
      raise Certificates::Error, I18n.t("errors.app.archived_delete")
    end
    { rollout_status: status, archived: archived }
  end

  def self.archive(record, actor:, expected_lookup_index:)
    raise Certificates::Error, I18n.t("errors.app.archive_consul_only") unless record.source == "consul"
    connection = client
    path = "#{prefix(record.area)}/lookups/#{record.lookup}"
    current = connection.get(path)
    unless (current&.fetch(:index) || 0).to_s == expected_lookup_index.to_s
      raise Certificates::Error, I18n.t("errors.app.archive_changed")
    end
    entry = current ? JSON.parse(current.fetch(:value)) : {}
    if entry["entry_id"] != record.entry_id
      raise Certificates::Error, I18n.t("errors.app.lookup_ownership")
    end
    previous = catalog_status(entry)
    return if previous.fetch(:archived)
    at = Time.current.iso8601(6)
    data = entry.merge("status" => "delete", "archived" => true, "archived_at" => at, "archived_by" => actor)
    snapshot = record.attributes.slice("common_name", "subject", "issuer", "serial", "fingerprint", "source", "source_id", "lookup").merge("kind" => "selected")
    audit = { action: "archive", area: record.area, id: record.source_id, actor: actor, at: at,
      details: { certificates: [snapshot], previous_status: previous.fetch(:rollout_status), status: "delete",
        previous_archived: false, archived: true, scope: "lookup",
        comment: "Archivierung bestätigt: aus der Übersicht ausgeblendet, weiterhin suchbar; Puppet-Löschauftrag gesetzt. Zertifikatsdaten und Schlüssel bleiben gespeichert." } }
    connection.transaction([
      ConsulConnection.set(path, data, index: current&.fetch(:index) || 0),
      ConsulConnection.set("#{namespace}/events/#{SecureRandom.uuid}", audit, index: 0)
    ])
  rescue ConsulConnection::Conflict => error
    raise Certificates::Error, I18n.t("errors.app.concurrent_change")
  end

  def self.namespace = ENV.fetch("CONSUL_PREFIX", "cci/v1")
  def self.client = ConsulConnection.new
  def self.prefix(area)
    raise Certificates::Error, I18n.t("errors.app.unknown_area") unless AreaConfiguration.ids.include?(area)
    "#{namespace}/areas/#{area}"
  end
  def self.get(area, id)
    raw = client.get("#{prefix(area)}/versions/#{id}")
    raise Certificates::Error, I18n.t("errors.app.missing_consul_certificate") unless raw
    JSON.parse(raw[:value])
  end
  def self.event(action, area, id, actor, data, previous_version: nil, changes: {})
    cert = OpenSSL::X509::Certificate.new(data.fetch(:pem) { data.fetch("pem") })
    details = { certificates: [AuditEvent.snapshot(cert).merge(source: "consul", source_id: id,
      lookup: data[:lookup] || data["lookup"], kind: "selected")], previous_version: previous_version,
      tags: JSON.parse(data[:tags] || data.fetch("tags")), has_key: (data[:has_key] || data["has_key"]) == "1" }
    ConsulConnection.set("#{namespace}/events/#{SecureRandom.uuid}",
      { action: action, area: area, id: id, actor: actor, at: Time.current.iso8601(6), details: details.merge(changes) })
  end
  def self.save(area:, cert:, key:, chain:, tags:, lookup:, actor:, client:, expected_lookup_index: nil)
    raise Certificates::Error, I18n.t("errors.app.client_format") unless client.is_a?(String) && client.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise Certificates::Error, I18n.t("errors.app.actor_format") unless actor.is_a?(String) && actor.strip.present? && actor.length <= 255
    validate_lookup!(lookup)
    base = prefix(area)
    connection = self.client
    lookup_key = "#{base}/lookups/#{lookup}"
    old = connection.get(lookup_key)
    if !expected_lookup_index.nil? && (old&.fetch(:index) || 0) != expected_lookup_index
      raise Certificates::Error, I18n.t("errors.app.preview_changed")
    end
    entry = old ? JSON.parse(old[:value]) : {}
    status = catalog_status(entry).fetch(:rollout_status)
    entry_id = entry.fetch("entry_id") { SecureRandom.uuid }
    fingerprint = Certificates::Codec.fingerprint(cert)
    id = Digest::SHA256.hexdigest("#{entry_id}:#{fingerprint}")
    version_key = "#{base}/versions/#{id}"
    raise Certificates::Error, I18n.t("errors.app.duplicate") if connection.get(version_key)
    envelope = key && Certificates::Vault.encrypt(key.private_to_pem, area: area, id: id)
    data = { schema: "1", entry_id: entry_id, lookup: lookup, pem: cert.to_pem,
      chain: JSON.generate(chain.map(&:to_pem)), tags: JSON.generate(tags),
      fingerprint: fingerprint, public_key_fingerprint: Digest::SHA256.hexdigest(cert.public_key.public_to_der),
      has_key: key ? "1" : "0", created_at: Time.current.iso8601, client: client, created_by: actor }
    operations = [ConsulConnection.set(lookup_key, entry.merge("entry_id" => entry_id, "active_version" => id, "status" => status), index: old&.fetch(:index) || 0),
      ConsulConnection.set(version_key, data, index: 0), event("import", area, id, actor, data,
        previous_version: old && JSON.parse(old[:value])["active_version"])]
    operations << ConsulConnection.set("#{base}/private-keys/#{id}", envelope, index: 0) if envelope
    connection.transaction(operations)
    id
  rescue ConsulConnection::Conflict => error
    raise Certificates::Error, I18n.t("errors.app.concurrent_change")
  end
  def self.activate(area, id, actor:)
    data = get(area, id)
    connection = client
    base = prefix(area)
    lookup_key = "#{base}/lookups/#{data.fetch('lookup')}"
    current = connection.get(lookup_key) || raise(Certificates::Error, I18n.t("errors.app.missing_lookup"))
    entry = JSON.parse(current[:value])
    raise Certificates::Error, I18n.t("errors.app.lookup_ownership") unless entry.fetch("entry_id") == data.fetch("entry_id")
    raise Certificates::Error, I18n.t("errors.app.archived_activation") if catalog_status(entry).fetch(:archived)
    version = connection.get("#{base}/versions/#{id}") || raise(Certificates::Error, I18n.t("errors.app.missing_version"))
    connection.transaction([
      { "Verb" => "check-index", "Key" => "#{base}/versions/#{id}", "Index" => version[:index] },
      ConsulConnection.set(lookup_key, entry.merge("active_version" => id, "status" => rollout_status(entry)), index: current[:index]),
      event("activate", area, id, actor, data, previous_version: JSON.parse(current[:value])["active_version"])
    ])
  end
  def self.set_status(area, id, status:, actor:, expected_lookup_index:)
    raise Certificates::Error, I18n.t("errors.app.invalid_status") unless ROLLOUT_STATUSES.include?(status)
    data = get(area, id)
    connection = client
    lookup_key = "#{prefix(area)}/lookups/#{data.fetch('lookup')}"
    current = connection.get(lookup_key) || raise(Certificates::Error, I18n.t("errors.app.missing_lookup"))
    raise Certificates::Error, I18n.t("errors.app.lookup_changed") unless current[:index].to_s == expected_lookup_index.to_s
    entry = JSON.parse(current[:value])
    raise Certificates::Error, I18n.t("errors.app.lookup_ownership") unless entry.fetch("entry_id") == data.fetch("entry_id")
    raise Certificates::Error, I18n.t("errors.app.archived_reactivation") if catalog_status(entry).fetch(:archived) && status != "delete"
    previous = rollout_status(entry)
    return if previous == status
    connection.transaction([
      ConsulConnection.set(lookup_key, entry.merge("status" => status), index: current[:index]),
      event("status_change", area, entry.fetch("active_version"), actor, get(area, entry.fetch("active_version")),
        changes: { previous_status: previous, status: status })
    ])
  rescue ConsulConnection::Conflict => error
    raise Certificates::Error, I18n.t("errors.app.concurrent_change")
  end

end
