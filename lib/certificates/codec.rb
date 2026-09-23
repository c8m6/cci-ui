# frozen_string_literal: true

require "openssl"
require "digest"

module Certificates
  # Detects supported input formats and normalises certificates, keys and display metadata.
  class Codec
    Result = Struct.new(:certificates, :keys, keyword_init: true)
    PRIVATE_KEY_PATTERN = /-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----/m
    MAX_BYTES = 20 * 1024 * 1024

    def self.parse(data, password: "")
      if data.empty? || data.bytesize > MAX_BYTES
        raise Error,
          Error.translate("errors.app.input_size",
            default: "The file is empty or larger than 20 MB.")
      end

      data = data.b
      return Jks.load(data, password: password) if data.start_with?([0xfeedfeed].pack("N"))

      if data.include?("-----BEGIN")
        certs = data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map { |pem| OpenSSL::X509::Certificate.new(pem) }
        keys = data.scan(PRIVATE_KEY_PATTERN).map do |pem|
          OpenSSL::PKey.read(pem, password)
        end
        if certs.empty? && keys.empty?
          raise Error,
            Error.translate("errors.app.unsupported_input",
              default: "No supported certificates or private keys found.")
        end

        return Result.new(certificates: certs, keys: keys)
      end
      begin
        return Result.new(certificates: [OpenSSL::X509::Certificate.new(data)], keys: [])
      rescue OpenSSL::OpenSSLError
        # DER certificates and PKCS#12 share ASN.1 encoding.
      end
      Pkcs12.load(data, password: password)
    rescue OpenSSL::OpenSSLError, ArgumentError
      raise Error,
        Error.translate("errors.app.parse_input",
          default: "The file could not be read. Check the format and password.")
    end

    def self.fingerprint(cert)
      Digest::SHA256.hexdigest(cert.to_der)
    end

    def self.common_name(name)
      entry = name.to_a.find { |item| item[0] == "CN" }
      return "No common name" unless entry

      _, value, type = entry
      encoding = case type
                 when OpenSSL::ASN1::BMPSTRING then Encoding::UTF_16BE
                 when OpenSSL::ASN1::UNIVERSALSTRING then Encoding::UTF_32BE
                 when OpenSSL::ASN1::T61STRING then Encoding::ISO_8859_1
                 else Encoding::UTF_8
                 end
      # Decode display text using the ASN.1 type; OpenSSL labels value bytes binary.
      value.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def self.metadata(cert)
      sans = cert.extensions.select { |e| e.oid == "subjectAltName" }.flat_map { |e| e.value.split(/,\s*/) }
      {
        common_name: common_name(cert.subject),
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
