class CertificateMaterial
  def self.load(record, private_key: false, password: "")
    if record.source == "consul"
      data = ConsulStore.get(record.area, record.source_id)
      cert = OpenSSL::X509::Certificate.new(data.fetch("pem"))
      chain = JSON.parse(data.fetch("chain")).map { |pem| OpenSSL::X509::Certificate.new(pem) }
      key = nil
      if private_key
        envelope = ConsulStore.client.get("#{ConsulStore.prefix(record.area)}/private-keys/#{record.source_id}")&.fetch(:value)
        raise Certificates::Error, "Kein privater Schlüssel vorhanden." unless envelope
        key = OpenSSL::PKey.read(Certificates::Vault.decrypt(envelope, area: record.area, id: record.source_id))
      end
    elsif record.source == "filesystem"
      relative, index = record.source_id.rpartition("#").values_at(0, 2)
      certificates = LegacyStore.certificates(relative, area: record.area)
      cert = certificates.fetch(Integer(index))
      chain = Certificates::Codec.chain(cert, certificates)
      key = private_key ? LegacyStore.key(relative, cert, password: password, area: record.area) : nil
    else
      raise Certificates::Error, "Diese Datenquelle wird nicht unterstützt."
    end
    raise Certificates::Error, "Die Quelle enthält inzwischen ein anderes Zertifikat. Der gespeicherte Eintrag bleibt erhalten; diese Version kann aus der aktuellen Quelle nicht exportiert werden." unless Certificates::Codec.fingerprint(cert) == record.fingerprint
    raise Certificates::Error, "Schlüssel passt nicht zum Zertifikat." if key && !cert.check_private_key(key)
    { certificate: cert, key: key, chain: Certificates::Codec.chain(cert, chain) }
  rescue IndexError, ArgumentError, OpenSSL::OpenSSLError
    raise Certificates::Error, "Zertifikatsdaten sind ungültig oder wurden geändert."
  end

  def self.with_chain(record, material, identity)
    candidates = material[:chain].dup
    current = candidates.last || material[:certificate]
    seen = [record.fingerprint, *candidates.map { |c| Certificates::Codec.fingerprint(c) }]
    12.times do
      break if current.subject == current.issuer && current.verify(current.public_key)
      issuer = current.issuer.to_s(OpenSSL::X509::Name::RFC2253)
      parent = Certificate.visible_to(identity).where(area: record.area, subject: issuer).limit(100).filter_map do |candidate|
        next if seen.include?(candidate.fingerprint)
        begin
          possible = load(candidate)[:certificate]
          possible if current.verify(possible.public_key)
        rescue Certificates::Error
          nil
        end
      end.first
      break unless parent
      candidates << parent
      seen << Certificates::Codec.fingerprint(parent)
      current = parent
    end
    material.merge(chain: Certificates::Codec.chain(material[:certificate], candidates))
  end
end
