class ConsulStore
  def self.namespace = ENV.fetch("CONSUL_PREFIX", "cci/v1")
  def self.client = ConsulConnection.new
  def self.prefix(area)
    raise Certificates::Error, "Unbekannter Bereich." unless AreaConfiguration.ids.include?(area)
    "#{namespace}/areas/#{area}"
  end
  def self.get(area, id)
    raw = client.get("#{prefix(area)}/versions/#{id}")
    raise Certificates::Error, "Zertifikat ist in Consul nicht mehr vorhanden." unless raw
    JSON.parse(raw[:value])
  end
  def self.event(action, area, id, actor, data, previous_version: nil)
    cert = OpenSSL::X509::Certificate.new(data.fetch(:pem) { data.fetch("pem") })
    details = { certificates: [AuditEvent.snapshot(cert).merge(source: "consul", source_id: id,
      lookup: data[:lookup] || data["lookup"], kind: "selected")], previous_version: previous_version,
      tags: JSON.parse(data[:tags] || data.fetch("tags")), has_key: (data[:has_key] || data["has_key"]) == "1" }
    ConsulConnection.set("#{namespace}/events/#{SecureRandom.uuid}",
      { action: action, area: area, id: id, actor: actor, at: Time.current.iso8601(6), details: details })
  end
  def self.save(area:, cert:, key:, chain:, tags:, lookup:, actor:, client:)
    raise Certificates::Error, "Client muss eine Kennung aus Buchstaben, Zahlen, Punkt, Unterstrich oder Bindestrich sein (max. 120)." unless client.is_a?(String) && client.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise Certificates::Error, "Urheber darf nicht leer sein (max. 255 Zeichen)." unless actor.is_a?(String) && actor.strip.present? && actor.length <= 255
    raise Certificates::Error, "Lookup darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten (max. 120)." unless lookup.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    base = prefix(area)
    connection = self.client
    lookup_key = "#{base}/lookups/#{lookup}"
    old = connection.get(lookup_key)
    entry_id = old ? JSON.parse(old[:value]).fetch("entry_id") : SecureRandom.uuid
    fingerprint = Certificates::Codec.fingerprint(cert)
    id = Digest::SHA256.hexdigest("#{entry_id}:#{fingerprint}")
    version_key = "#{base}/versions/#{id}"
    raise Certificates::Error, "Dieses Zertifikat ist unter diesem Lookup bereits vorhanden." if connection.get(version_key)
    envelope = key && Certificates::Vault.encrypt(key.private_to_pem, area: area, id: id)
    data = { schema: "1", entry_id: entry_id, lookup: lookup, pem: cert.to_pem,
      chain: JSON.generate(chain.map(&:to_pem)), tags: JSON.generate(tags),
      fingerprint: fingerprint, public_key_fingerprint: Digest::SHA256.hexdigest(cert.public_key.public_to_der),
      has_key: key ? "1" : "0", created_at: Time.current.iso8601, client: client, created_by: actor }
    operations = [ConsulConnection.set(lookup_key, { entry_id: entry_id, active_version: id }, index: old&.fetch(:index) || 0),
      ConsulConnection.set(version_key, data, index: 0), event("import", area, id, actor, data,
        previous_version: old && JSON.parse(old[:value])["active_version"])]
    operations << ConsulConnection.set("#{base}/private-keys/#{id}", envelope, index: 0) if envelope
    connection.transaction(operations)
    id
  rescue ConsulConnection::Conflict => error
    raise Certificates::Error, error.message
  end
  def self.activate(area, id, actor:)
    data = get(area, id)
    connection = client
    base = prefix(area)
    lookup_key = "#{base}/lookups/#{data.fetch('lookup')}"
    current = connection.get(lookup_key) || raise(Certificates::Error, "Lookup ist nicht mehr vorhanden.")
    version = connection.get("#{base}/versions/#{id}") || raise(Certificates::Error, "Version wurde entfernt.")
    connection.transaction([
      { "Verb" => "check-index", "Key" => "#{base}/versions/#{id}", "Index" => version[:index] },
      ConsulConnection.set(lookup_key, { entry_id: data.fetch("entry_id"), active_version: id }, index: current[:index]),
      event("activate", area, id, actor, data, previous_version: JSON.parse(current[:value])["active_version"])
    ])
  end
  def self.delete(area, id, actor:)
    data = get(area, id)
    base = prefix(area)
    lookup_key = "#{base}/lookups/#{data.fetch('lookup')}"
    connection = client
    current = connection.get(lookup_key) || raise(Certificates::Error, "Lookup ist nicht mehr vorhanden.")
    raise Certificates::Error, "Aktive Versionen können nicht gelöscht werden. Zuerst eine andere Version aktivieren." if JSON.parse(current[:value])["active_version"] == id
    connection.transaction([
      { "Verb" => "check-index", "Key" => lookup_key, "Index" => current[:index] },
      { "Verb" => "delete", "Key" => "#{base}/versions/#{id}" },
      { "Verb" => "delete", "Key" => "#{base}/private-keys/#{id}" },
      event("delete", area, id, actor, data)
    ])
  end
end
