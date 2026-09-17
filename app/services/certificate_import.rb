class CertificateImport
  class ConfirmationRequired < Certificates::Error
    attr_reader :preview

    def initialize(preview)
      @preview = preview
      super(I18n.t("errors.app.overwrite_confirmation"))
    end
  end

  def self.preview(files:, pem:, password:, areas:, tags:, lookup:, owner:)
    raise Certificates::Error, I18n.t("errors.app.choose_area") if areas.empty? || (areas - AreaConfiguration.ids).any?
    inputs = files.map { |file| file.read(Certificates::Codec::MAX_BYTES + 1) }
    inputs << pem if pem.present?
    raise Certificates::Error, I18n.t("errors.app.choose_input") if inputs.empty?
    raise Certificates::Error, I18n.t("errors.app.import_size") if inputs.sum(&:bytesize) > Certificates::Codec::MAX_BYTES
    parsed = inputs.map { |input| Certificates::Codec.parse(input, password: password) }
    certs = parsed.flat_map(&:certificates).uniq { |cert| cert.to_der }
    keys = parsed.flat_map(&:keys).uniq { |key| key.public_to_der }
    raise Certificates::Error, I18n.t("errors.app.no_certificates") if certs.empty?
    raise Certificates::Error, I18n.t("errors.app.import_count") if certs.size > 100
    raise Certificates::Error, I18n.t("errors.app.unmatched_key") if keys.any? { |key| certs.none? { |cert| cert.check_private_key(key) } }
    raise Certificates::Error, I18n.t("errors.app.single_lookup") if lookup.present? && certs.size > 1
    LegacyStore.reject_duplicates!(certs.map { |cert| Certificates::Codec.fingerprint(cert) })
    token = SecureRandom.hex(24)
    entries = areas.flat_map do |area|
      certs.map do |cert|
        key = keys.find { |candidate| cert.check_private_key(candidate) }
        fingerprint = Certificates::Codec.fingerprint(cert)
        name = lookup.presence || fingerprint
        snapshot = ConsulStore.lookup_snapshot(area, name)
        previous = snapshot && JSON.parse(snapshot.fetch(:value))
        { area: area, pem: cert.to_pem, fingerprint: fingerprint, name: Certificates::Codec.metadata(cert)[:common_name],
          key: key && Certificates::Vault.encrypt(key.private_to_pem, area: area, id: "preview:#{token}:#{fingerprint}"),
          chain: Certificates::Codec.chain(cert, certs).map(&:to_pem), lookup: name,
          lookup_index: snapshot&.fetch(:index) || 0, previous_version: previous && previous.fetch("active_version"),
          rollout_status: previous ? ConsulStore.rollout_status(previous) : "active",
          tags: tags.split(",").map(&:strip).reject(&:empty?).first(30) }
      end
    end
    payload = { areas: areas, entries: entries }
    ImportDraft.create!(token: token, owner: owner, payload: JSON.generate(payload), expires_at: 15.minutes.from_now)
    [token, payload.deep_stringify_keys]
  end

  def self.commit(token:, owner:, identity:, confirm_overwrite: false)
    raise Certificates::Error, I18n.t("errors.app.invalid_preview") unless token.match?(/\A[0-9a-f]{48}\z/)
    payload = ImportDraft.transaction do
      draft = ImportDraft.lock.find_by(token: token, owner: owner)
      raise Certificates::Error, I18n.t("errors.app.expired_preview") unless draft && draft.expires_at > Time.current
      data = JSON.parse(draft.payload)
      raise Certificates::Error, I18n.t("errors.app.write_areas") unless data.fetch("areas").all? { |area| identity.writer?(area) }
      unless data.fetch("entries").all? { |entry| entry["lookup_index"].is_a?(Integer) && entry["lookup_index"] >= 0 }
        raise Certificates::Error, I18n.t("errors.app.old_preview")
      end
      if data.fetch("entries").any? { |entry| entry.fetch("lookup_index") > 0 } && !confirm_overwrite
        raise ConfirmationRequired.new(data)
      end
      LegacyStore.reject_duplicates!(data.fetch("entries").map { |entry| entry.fetch("fingerprint") }.uniq)
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
          tags: entry.fetch("tags"), lookup: entry.fetch("lookup"), actor: identity.name, client: "cci-ui",
          expected_lookup_index: entry.fetch("lookup_index"))
        successes << id
      rescue Certificates::Error, ConsulConnection::Error => error
        Rails.logger.error(error.full_message(highlight: false))
        message = error.is_a?(ConsulConnection::Error) ? I18n.t("errors.app.store_unavailable") : error.message
        errors << "#{AreaConfiguration.label(area)} / #{entry.fetch('name')}: #{message}"
      end
    end
    CatalogIndexer.refresh_consul
    [successes, errors]
  end
end
