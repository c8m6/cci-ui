# frozen_string_literal: true

module CertificateDiagnostics
  # Area-local untrusted candidates, independent of optional CA inventory.
  class Material
    attr_reader :certificate, :candidates, :identity

    def self.inventory_version(area, fingerprint)
      Inventory.new(area).version(fingerprint)
    end

    def initialize(record)
      @record = record
      loaded = CertificateMaterial.load(record)
      @certificate = loaded.fetch(:certificate)
      @identity = self.class.inventory_version(record.area, record.fingerprint)
      @candidates = loaded.fetch(:chain)
      # Walk every issuer candidate, including alternate and cross-signed paths.
      frontier = [certificate, *candidates]
      seen = {}
      CciClient::MAX_CHAIN_ISSUERS.times do
        parents = frontier.flat_map { |cert| load_parents(cert, seen) }
        break if parents.empty?

        @candidates.concat(parents)
        frontier = parents
      end
      @candidates.uniq! { |cert| Certificates::Codec.fingerprint(cert) }
    end

    def issuer
      candidates.find { |candidate| candidate.subject == certificate.issuer && CertificateMaterial.issuer?(candidate, certificate) }
    end

    def self_signed? = certificate.subject == certificate.issuer && certificate.verify(certificate.public_key)

    def current?
      current = Certificate.retained.find_by(id: @record.id, fingerprint: @record.fingerprint, area: @record.area)
      current && self.class.inventory_version(current.area, current.fingerprint) == identity &&
        CertificateMaterial.load(current).fetch(:certificate).to_der == certificate.to_der
    rescue Certificates::Error
      false
    end

    private

    def load_parents(cert, seen)
      subject = cert.issuer.to_s(OpenSSL::X509::Name::RFC2253)
      Certificate.retained.where(area: @record.area, subject: subject).order(:id).limit(100).filter_map do |candidate|
        next if seen[candidate.fingerprint]

        seen[candidate.fingerprint] = true
        CertificateMaterial.load(candidate).fetch(:certificate)
      rescue Certificates::Error
        nil
      end
    end
  end
end
