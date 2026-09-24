# frozen_string_literal: true

# Retains matching issued certificates before attempting any external publication.
class CsrUpload
  def self.call(request, data:, identity:, replace: false)
    CsrWorkflow.authorize!(identity, request.area)
    certificates = CsrCertificateCheck.parse(data)
    cert = CsrCertificateCheck.match(request, certificates)
    issuers = certificates.reject { |item| item.to_der == cert.to_der }.map(&:to_pem)
    verification = CsrCertificateCheck.verify(cert, area: request.area, issuer_pems: issuers)
    CsrNames.fail!(:signature) if verification == "invalid"

    CatalogIndexer.synchronize do
      request.with_lock do
        fingerprint = Certificates::Codec.fingerprint(cert)
        validate_replacement!(request, replace, fingerprint)

        metadata = Certificates::Codec.metadata(cert).slice(:subject, :issuer, :not_before, :not_after, :sans, :fingerprint)
        entry = request.csr_certificates.create!(metadata.merge(pem: cert.to_pem, issuer_pems: issuers,
          uploaded_by: identity.name, state: verification == "verified" ? "pending" : "awaiting_issuer",
          verified_at: verification == "verified" ? Time.current : nil))
        CsrAudit.record!("csr_upload", request, identity, outcome: "succeeded", certificate_id: entry.id, fingerprint: fingerprint)
        entry
      end
    end
  rescue Certificates::Error
    CsrAudit.record!("csr_upload", request, identity, outcome: "rejected") if identity.csr?(request.area)
    raise
  end

  def self.validate_replacement!(request, replace, fingerprint)
    previous = request.latest_certificate
    CsrNames.fail!(:replace_confirmation) if previous && !replace
    CsrNames.fail!(:unresolved_publication) if previous&.prepared&.any? && previous.state != "published"
    CsrNames.fail!(:duplicate) if request.csr_certificates.exists?(fingerprint: fingerprint)
  end

  def self.add_issuers(request, entry, data:, identity:)
    CsrWorkflow.authorize!(identity, request.area)
    certs = CsrCertificateCheck.parse(data)
    CatalogIndexer.synchronize do
      request.with_lock do
        entry.reload
        CsrNames.fail!(:stale) unless request.latest_certificate&.id == entry.id && entry.state != "published"
        CsrNames.fail!(:unresolved_publication) if entry.prepared.any?
        issuers = (entry.issuer_pems + certs.map(&:to_pem)).uniq
        CsrNames.fail!(:format) if issuers.size > 20
        result = CsrCertificateCheck.verify(OpenSSL::X509::Certificate.new(entry.pem), area: request.area, issuer_pems: issuers)
        CsrNames.fail!(:signature) if result == "invalid"
        entry.update!(issuer_pems: issuers, state: result == "verified" ? "pending" : "awaiting_issuer",
          verified_at: result == "verified" ? Time.current : nil, error_code: nil)
        CsrAudit.record!("csr_verify", request, identity, outcome: result, certificate_id: entry.id)
      end
    end
    entry
  rescue Certificates::Error
    CsrAudit.record!("csr_verify", request, identity, outcome: "rejected", certificate_id: entry.id) if identity.csr?(request.area)
    raise
  end
end
