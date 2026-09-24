# frozen_string_literal: true

# Reloads source bytes and verifies identity against the indexed certificate.
class CertificateMaterial
  def self.load(record, private_key: false, password: "")
    record.require_retained!

    if record.source == "consul"
      base = ConsulStore.prefix(record.area)
      paths = ["#{base}/certs/#{record.source_id}"]
      paths << "#{base}/keys/#{record.source_id}" if private_key
      values = ConsulStore.client.get_many(paths)
      data = JSON.parse(values.fetch(paths.first).fetch(:value))
      cert = OpenSSL::X509::Certificate.new(data.fetch("pem"))
      chain = []
      key = private_key && OpenSSL::PKey.read(Certificates::Vault.decrypt(values.fetch(paths.last).fetch(:value),
        area: record.area, id: record.source_id))
    elsif record.source == "filesystem"
      relative, index = record.source_id.rpartition("#").values_at(0, 2)
      certificates = LegacyStore.certificates(relative, area: record.area)
      cert = certificates.fetch(Integer(index))
      chain = Certificates::Codec.chain(cert, certificates)
      key = private_key ? LegacyStore.key(relative, cert, password: password, area: record.area) : nil
    else
      raise Certificates::Error, I18n.t("errors.app.unsupported_source")
    end
    unless Certificates::Codec.fingerprint(cert) == record.fingerprint
      raise Certificates::Error,
        I18n.t("errors.app.source_changed")
    end
    raise Certificates::Error, I18n.t("errors.app.key_mismatch") if key && !cert.check_private_key(key)

    { certificate: cert, key: key, chain: Certificates::Codec.chain(cert, chain) }
  rescue ConsulConnection::Error, IndexError, ArgumentError, OpenSSL::OpenSSLError
    raise Certificates::Error, I18n.t("errors.app.invalid_material")
  end

  def self.with_chain(record, material, identity)
    candidates = material[:chain].dup
    current = candidates.last || material[:certificate]
    seen = [record.fingerprint, *candidates.map { |c| Certificates::Codec.fingerprint(c) }]
    # Match the standalone client limit: twelve issuer hops bound signature work.
    CciClient::MAX_CHAIN_ISSUERS.times do
      break if current.subject == current.issuer && current.verify(current.public_key)

      issuer = current.issuer.to_s(OpenSSL::X509::Name::RFC2253)
      parent = Certificate.visible_to(identity).where(area: record.area,
        subject: issuer).limit(100).filter_map do |candidate|
        next if seen.include?(candidate.fingerprint)

        begin
          possible = load(candidate)[:certificate]
          possible if issuer?(possible, current)
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

  # Matching a subject name is insufficient without CA status and a valid signature.
  def self.issuer?(candidate, certificate)
    candidate.extensions.any? { |extension| extension.oid == "basicConstraints" && extension.value.include?("CA:TRUE") } &&
      certificate.verify(candidate.public_key)
  end
end
