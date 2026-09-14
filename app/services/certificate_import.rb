class CertificateImport
  def self.preview(files:, pem:, password:, areas:, tags:, lookup:, owner:)
    raise Certificates::Error, "Bitte mindestens einen gültigen Bereich auswählen." if areas.empty? || (areas - AreaConfiguration.ids).any?
    inputs = files.map { |file| file.read(Certificates::Codec::MAX_BYTES + 1) }
    inputs << pem if pem.present?
    raise Certificates::Error, "Bitte Dateien auswählen oder PEM eingeben." if inputs.empty?
    raise Certificates::Error, "Insgesamt höchstens 20 MB pro Import." if inputs.sum(&:bytesize) > Certificates::Codec::MAX_BYTES
    parsed = inputs.map { |input| Certificates::Codec.parse(input, password: password) }
    certs = parsed.flat_map(&:certificates).uniq { |cert| cert.to_der }
    keys = parsed.flat_map(&:keys).uniq { |key| key.public_to_der }
    raise Certificates::Error, "Keine Zertifikate gefunden." if certs.empty?
    raise Certificates::Error, "Höchstens 100 Zertifikate pro Import." if certs.size > 100
    raise Certificates::Error, "Mindestens ein Schlüssel passt zu keinem Zertifikat." if keys.any? { |key| certs.none? { |cert| cert.check_private_key(key) } }
    raise Certificates::Error, "Ein eigener Lookup ist nur beim Import eines einzelnen Zertifikats möglich." if lookup.present? && certs.size > 1
    token = SecureRandom.hex(24)
    entries = areas.flat_map do |area|
      certs.map do |cert|
        key = keys.find { |candidate| cert.check_private_key(candidate) }
        fingerprint = Certificates::Codec.fingerprint(cert)
        { area: area, pem: cert.to_pem, fingerprint: fingerprint, name: Certificates::Codec.metadata(cert)[:common_name],
          key: key && Certificates::Vault.encrypt(key.private_to_pem, area: area, id: "preview:#{token}:#{fingerprint}"),
          chain: Certificates::Codec.chain(cert, certs).map(&:to_pem), lookup: lookup.presence || fingerprint,
          tags: tags.split(",").map(&:strip).reject(&:empty?).first(30) }
      end
    end
    payload = { areas: areas, entries: entries }
    ImportDraft.create!(token: token, owner: owner, payload: JSON.generate(payload), expires_at: 15.minutes.from_now)
    [token, payload.deep_stringify_keys]
  end

  def self.commit(token:, owner:, identity:)
    raise Certificates::Error, "Ungültige Importvorschau." unless token.match?(/\A[0-9a-f]{48}\z/)
    payload = ImportDraft.transaction do
      draft = ImportDraft.lock.find_by(token: token, owner: owner)
      raise Certificates::Error, "Vorschau abgelaufen oder nicht für diese Sitzung vorhanden." unless draft && draft.expires_at > Time.current
      data = JSON.parse(draft.payload)
      raise Certificates::Error, "Keine Schreibberechtigung für alle gewählten Bereiche." unless data.fetch("areas").all? { |area| identity.writer?(area) }
      draft.destroy!
      data
    end
    successes, errors = [], []
    payload.fetch("entries").each do |entry|
      area = entry.fetch("area")
      begin
        cert = OpenSSL::X509::Certificate.new(entry.fetch("pem"))
        key = entry["key"] && OpenSSL::PKey.read(Certificates::Vault.decrypt(entry["key"], area: area, id: "preview:#{token}:#{entry.fetch('fingerprint')}"))
        id = ConsulStore.save(area: area, cert: cert, key: key,
          chain: entry.fetch("chain").map { |pem| OpenSSL::X509::Certificate.new(pem) },
          tags: entry.fetch("tags"), lookup: entry.fetch("lookup"), actor: identity.name, client: "cci-ui")
        successes << id
      rescue Certificates::Error, ConsulConnection::Error => error
        errors << "#{AreaConfiguration.label(area)} / #{entry.fetch('name')}: #{error.message}"
      end
    end
    CatalogIndexer.refresh_consul
    [successes, errors]
  end
end
