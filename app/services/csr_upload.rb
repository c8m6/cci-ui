# frozen_string_literal: true

# Retains matching issued certificates before attempting any external publication.
class CsrUpload
  def self.call(request, data:, identity:, replace: false)
    CsrWorkflow.authorize!(identity, request.areas)
    certificates = CsrCertificateCheck.parse(data)
    cert = CsrCertificateCheck.match(request, certificates)
    issuers = certificates.reject { |item| item.to_der == cert.to_der }.map(&:to_pem)
    verification = verification(request, cert, issuers)

    CatalogIndexer.synchronize do
      request.with_lock do
        fingerprint = Certificates::Codec.fingerprint(cert)
        validate_replacement!(request, replace, fingerprint)

        metadata = Certificates::Codec.metadata(cert).slice(:subject, :issuer, :not_before, :not_after, :sans, :fingerprint)
        entry = request.csr_certificates.create!(metadata.merge(pem: cert.to_pem, issuer_pems: issuers,
          uploaded_by: identity.uid, state: verification == "verified" ? "pending" : "awaiting_issuer",
          verified_at: verification == "verified" ? Time.current : nil))
        CsrAudit.record!("csr_upload", request, identity, outcome: "succeeded", certificate_id: entry.id,
          fingerprint: fingerprint)
        entry
      end
    end
  rescue Certificates::Error
    CsrAudit.record!("csr_upload", request, identity, outcome: "rejected") if authorized?(request, identity)
    raise
  end

  def self.validate_replacement!(request, replace, fingerprint)
    previous = request.latest_certificate
    CsrNames.fail!(:replace_confirmation) if previous && !replace
    CsrNames.fail!(:unresolved_publication) if previous&.prepared&.any? && previous.state != "published"
    CsrNames.fail!(:duplicate) if request.csr_certificates.exists?(fingerprint: fingerprint)
  end

  def self.add_issuers(request, entry, data:, identity:)
    CsrWorkflow.authorize!(identity, request.areas)
    certs = CsrCertificateCheck.parse(data)
    CatalogIndexer.synchronize { update_issuers(request, entry, certs, identity) }
    entry
  rescue Certificates::Error
    CsrAudit.record!("csr_verify", request, identity, outcome: "rejected", certificate_id: entry.id) if authorized?(request, identity)
    raise
  end

  def self.update_issuers(request, entry, certs, identity)
    request.with_lock do
      entry.reload
      CsrNames.fail!(:stale) unless request.latest_certificate&.id == entry.id && entry.state != "published"
      CsrNames.fail!(:unresolved_publication) if entry.prepared.any?
      issuers = (entry.issuer_pems + certs.map(&:to_pem)).uniq
      CsrNames.fail!(:format) if issuers.size > 20
      result = verification(request, OpenSSL::X509::Certificate.new(entry.pem), issuers)
      entry.update!(issuer_pems: issuers, state: result == "verified" ? "pending" : "awaiting_issuer",
        verified_at: result == "verified" ? Time.current : nil, error_code: nil)
      CsrAudit.record!("csr_verify", request, identity, outcome: result, certificate_id: entry.id)
    end
  end
  private_class_method :update_issuers

  def self.verification(request, cert, issuers)
    results = request.areas.map { |area| CsrCertificateCheck.verify(cert, area: area, issuer_pems: issuers) }
    CsrNames.fail!(:signature) if results.include?("invalid")

    results.include?("missing") ? "missing" : "verified"
  end
  private_class_method :verification

  def self.authorized?(request, identity)
    request.areas.all? { |area| identity.csr?(area) }
  end
  private_class_method :authorized?
end
