# frozen_string_literal: true

# Validates complete uploads and encrypts drafts before publishing confirmed versions.
class CertificateImport
  # Carries renewal details back to the preview without publishing a new version.
  class ConfirmationRequired < Certificates::Error
    attr_reader :preview

    def initialize(preview)
      @preview = preview
      super(I18n.t("errors.app.overwrite_confirmation"))
    end
  end

  def self.preview(files:, pem:, password:, areas:, tags:, certid:, owner:)
    raise Certificates::Error, I18n.t("errors.app.choose_area") if areas.empty? || (areas - AreaConfiguration.ids).any?

    certs, keys = parse_upload(files, pem, password, certid)

    LegacyStore.reject_duplicates!(certs.map { |cert| Certificates::Codec.fingerprint(cert) })
    token = SecureRandom.hex(24)
    entries = areas.flat_map do |area|
      certs.map do |cert|
        preview_entry(area: area, cert: cert, keys: keys, certid: certid, token: token, tags: tags)
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
      validate_draft(data, identity, confirm_overwrite)

      LegacyStore.reject_duplicates!(data.fetch("entries").map { |entry| entry.fetch("fingerprint") }.uniq)
      draft.destroy!
      data
    end
    successes = []
    errors = []
    payload.fetch("entries").each do |entry|
      area = entry.fetch("area")
      begin
        cert = OpenSSL::X509::Certificate.new(entry.fetch("pem"))
        key = entry["key"] && OpenSSL::PKey.read(Certificates::Vault.decrypt(entry["key"], area: area,
          id: "preview:#{token}:#{entry.fetch("fingerprint")}"))
        id = ConsulStore.save(area: area, cert: cert, key: key,
          tags: entry.fetch("tags"), certid: entry.fetch("certid"), actor: identity.name, client: "cci-ui",
          expected_certid_index: entry.fetch("certid_index"))
        successes << id
      rescue Certificates::Error, ConsulConnection::Error => e
        OperationalLog.failure(logger: "cci.certificates", message: "Certificate import entry failed", error: e,
          operation: "import_certificate", area: area)
        message = e.is_a?(ConsulConnection::Error) ? I18n.t("errors.app.store_unavailable") : e.message
        errors << "#{AreaConfiguration.label(area)} / #{entry.fetch("name")}: #{message}"
      end
    end
    CatalogIndexer.refresh_consul
    [successes, errors]
  end

  # Parse all inputs before rejecting unmatched keys or ambiguous CertID assignment.
  def self.parse_upload(files, pem, password, certid)
    inputs = files.map { |file| file.read(Certificates::Codec::MAX_BYTES + 1) }
    inputs << pem if pem.present?
    raise Certificates::Error, I18n.t("errors.app.choose_input") if inputs.empty?
    raise Certificates::Error, I18n.t("errors.app.import_size") if inputs.sum(&:bytesize) > Certificates::Codec::MAX_BYTES

    parsed = inputs.map { |input| Certificates::Codec.parse(input, password: password) }
    certs = parsed.flat_map(&:certificates).uniq(&:to_der)
    keys = parsed.flat_map(&:keys).uniq(&:public_to_der)
    validate_material(certs, keys, certid)

    [certs, keys]
  end

  # Encrypt each preview key with a draft-specific context and capture the CAS index.
  def self.preview_entry(area:, cert:, keys:, certid:, token:, tags:)
    key = keys.find { |candidate| cert.check_private_key(candidate) }
    fingerprint = Certificates::Codec.fingerprint(cert)
    name = certid.presence || fingerprint
    snapshot = ConsulStore.certid_snapshot(area, name)
    previous = snapshot && JSON.parse(snapshot.fetch(:value))
    { area: area, pem: cert.to_pem, fingerprint: fingerprint, name: Certificates::Codec.metadata(cert)[:common_name],
      key: key && Certificates::Vault.encrypt(key.private_to_pem, area: area, id: "preview:#{token}:#{fingerprint}"),
      certid: name,
      certid_index: snapshot&.fetch(:index) || 0, previous_version: previous&.fetch("active_version"),
      rollout_status: previous ? ConsulStore.rollout_status(previous) : "active",
      tags: tags.split(",").map(&:strip).reject(&:empty?).first(30) }
  end

  # Recheck permissions and renewal confirmation when consuming the draft.
  def self.validate_draft(data, identity, confirm_overwrite)
    raise Certificates::Error, I18n.t("errors.app.write_areas") unless data.fetch("areas").all? { |area| identity.writer?(area) }
    unless data.fetch("entries").all? { |entry| entry["certid_index"].is_a?(Integer) && entry["certid_index"] >= 0 }
      raise Certificates::Error, I18n.t("errors.app.old_preview")
    end
    raise ConfirmationRequired, data if data.fetch("entries").any? { |entry| entry.fetch("certid_index").positive? } && !confirm_overwrite
  end

  # A supplied CertID may refer to one certificate only and every key must match.
  def self.validate_material(certs, keys, certid)
    raise Certificates::Error, I18n.t("errors.app.no_certificates") if certs.empty?
    raise Certificates::Error, I18n.t("errors.app.import_count") if certs.size > 100
    raise Certificates::Error, I18n.t("errors.app.unmatched_key") if keys.any? { |key| certs.none? { |cert| cert.check_private_key(key) } }
    raise Certificates::Error, I18n.t("errors.app.single_certid") if certid.present? && certs.size > 1
  end
end
