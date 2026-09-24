# frozen_string_literal: true

# Checks issued TLS identities and cryptographic issuer signatures, not public trust or revocation.
class CsrCertificateCheck
  def self.parse(data)
    CsrNames.fail!(:format) if data.blank? || data.bytesize > Certificates::Codec::MAX_BYTES

    if data.include?("-----BEGIN")
      blocks = data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
      remainder = data.gsub(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m, "").strip
      CsrNames.fail!(:format) unless blocks.any? && blocks.size <= 20 && remainder.empty?

      blocks.map { |block| OpenSSL::X509::Certificate.new(block) }.uniq(&:to_der)
    else
      cert = OpenSSL::X509::Certificate.new(data)
      CsrNames.fail!(:format) unless cert.to_der == data.b

      [cert]
    end
  rescue OpenSSL::OpenSSLError, ArgumentError
    CsrNames.fail!(:format)
  end

  def self.match(request, certificates)
    csr = OpenSSL::X509::Request.new(request.csr_pem)
    CsrNames.fail!(:mismatch) unless csr.verify(csr.public_key)

    matches = certificates.select { |cert| cert.public_key.public_to_der == csr.public_key.public_to_der }
    CsrNames.fail!(:mismatch) unless matches.size == 1

    cert = matches.first
    cn = cert.subject.to_a.select { |entry| entry[0] == "CN" }
    expected = CsrNames.name(request.common_name)
    CsrNames.fail!(:mismatch) unless cn.size == 1 && CsrNames.name(cn.first[1]) == expected
    CsrNames.fail!(:mismatch) unless CsrNames.certificate_sans(cert) == request.sans.sort
    CsrNames.fail!(:dates) unless cert.not_before < cert.not_after

    cert
  end

  def self.verify(cert, area:, issuer_pems:)
    return cert.verify(cert.public_key) ? "verified" : "invalid" if cert.issuer == cert.subject

    candidates = issuer_pems.map { |pem| OpenSSL::X509::Certificate.new(pem) }
    issuer = cert.issuer.to_s(OpenSSL::X509::Name::RFC2253)
    Certificate.retained.where(area: area, subject: issuer).find_each do |record|
      candidates << CertificateMaterial.load(record).fetch(:certificate)
    rescue Certificates::Error, ConsulConnection::Error
      # Unavailable source material cannot verify a signature.
    end
    candidates.select! { |candidate| candidate.subject == cert.issuer }
    return "missing" if candidates.empty?

    candidates.any? { |candidate| issuer?(candidate, cert) } ? "verified" : "invalid"
  rescue OpenSSL::OpenSSLError, ArgumentError
    "invalid"
  end

  def self.issuer?(candidate, cert)
    usage = candidate.extensions.find { |extension| extension.oid == "keyUsage" }
    CertificateMaterial.issuer?(candidate, cert) && (!usage || usage.value.include?("Certificate Sign"))
  end
end
