# frozen_string_literal: true

# Presents the resolved chain from its highest available issuer to the selected certificate.
module CertificatesHelper
  def certificate_chain_group(material, records, selected)
    rows = [material.fetch(:certificate), *material.fetch(:chain)].reverse.each_with_index.map do |cert, depth|
      fingerprint = Certificates::Codec.fingerprint(cert)
      current = fingerprint == selected.fingerprint
      record = current ? selected : records[fingerprint]
      entry = { "subject" => cert.subject.to_s(OpenSSL::X509::Name::RFC2253),
                "fingerprint" => fingerprint, "certificate_id" => record&.id,
                "kind" => chain_certificate_kind(cert), "selected" => current,
                "not_before" => cert.not_before.iso8601, "not_after" => cert.not_after.iso8601 }
      { entry: entry, depth: depth }
    end
    { root: rows.first.fetch(:entry), rows: rows }
  end

  def chain_certificate_kind(cert)
    ca = cert.extensions.any? { |extension| extension.oid == "basicConstraints" && extension.value.include?("CA:TRUE") }
    return "certificate" unless ca

    cert.subject == cert.issuer && cert.verify(cert.public_key) ? "root" : "intermediate"
  end
end
