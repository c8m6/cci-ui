require "openssl"
require "digest"

module Certificates
  class Codec
    Result = Struct.new(:certificates, :keys, keyword_init: true)
    MAX_BYTES = 20 * 1024 * 1024

    def self.parse(data, password: "")
      raise Error, "Datei ist leer oder größer als 20 MB." if data.empty? || data.bytesize > MAX_BYTES
      data = data.b
      if data.start_with?([0xfeedfeed].pack("N"))
        return Jks.load(data, password: password)
      end
      if data.include?("-----BEGIN")
        certs = data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map { |pem| OpenSSL::X509::Certificate.new(pem) }
        keys = data.scan(/-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----/m).map { |pem| OpenSSL::PKey.read(pem, password) }
        raise Error, "Keine unterstützten Zertifikate oder privaten Schlüssel gefunden." if certs.empty? && keys.empty?
        return Result.new(certificates: certs, keys: keys)
      end
      begin
        return Result.new(certificates: [OpenSSL::X509::Certificate.new(data)], keys: [])
      rescue OpenSSL::OpenSSLError
        # DER certificates and PKCS#12 share ASN.1 encoding.
      end
      Pkcs12.load(data, password: password)
    rescue OpenSSL::OpenSSLError, ArgumentError
      raise Error, "Datei konnte nicht gelesen werden. Format und Passwort prüfen."
    end

    def self.fingerprint(cert)
      Digest::SHA256.hexdigest(cert.to_der)
    end

    def self.metadata(cert)
      sans = cert.extensions.select { |e| e.oid == "subjectAltName" }.flat_map { |e| e.value.split(/,\s*/) }
      {
        common_name: cert.subject.to_a.find { |entry| entry[0] == "CN" }&.at(1) || "Ohne Common Name",
        subject: cert.subject.to_s(OpenSSL::X509::Name::RFC2253),
        issuer: cert.issuer.to_s(OpenSSL::X509::Name::RFC2253),
        serial: cert.serial.to_i.to_s(16), fingerprint: fingerprint(cert),
        not_before: cert.not_before, not_after: cert.not_after, sans: sans,
        algorithm: cert.signature_algorithm
      }
    end

    def self.chain(leaf, candidates)
      result = []
      seen = [fingerprint(leaf)]
      current = leaf
      loop do
        break if current.subject == current.issuer && current.verify(current.public_key)
        parent = candidates.find do |cert|
          !seen.include?(fingerprint(cert)) && cert.subject == current.issuer && current.verify(cert.public_key)
        end
        break unless parent
        result << parent
        seen << fingerprint(parent)
        current = parent
      end
      result
    end
  end
end
