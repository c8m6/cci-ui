# frozen_string_literal: true

require "openssl"
require "digest"

module Certificates
  # ASN.1 container handling per RFC 7292 / RFC 8018. Crypto primitives use
  # Ruby OpenSSL. Unlike PKCS12#key, this reads every key bag in a container.
  class Pkcs12
    DATA = "1.2.840.113549.1.7.1"
    ENCRYPTED = "1.2.840.113549.1.7.6"
    CERT_BAG = "1.2.840.113549.1.12.10.1.3"
    KEY_BAG = "1.2.840.113549.1.12.10.1.1"
    SHROUDED_KEY = "1.2.840.113549.1.12.10.1.2"
    SAFE_BAG = "1.2.840.113549.1.12.10.1.6"
    # PKCS#9 attributes and PKCS#5 encryption algorithm identifiers.
    X509_CERTIFICATE = "1.2.840.113549.1.9.22.1"
    FRIENDLY_NAME = "1.2.840.113549.1.9.20"
    LOCAL_KEY_ID = "1.2.840.113549.1.9.21"
    PBES2 = "1.2.840.113549.1.5.13"
    PBKDF2 = "1.2.840.113549.1.5.12"
    PBE_SHA1_3DES = "1.2.840.113549.1.12.1.3"
    HMAC_SHA256 = "1.2.840.113549.2.9"
    AES256_CBC = "2.16.840.1.101.3.4.1.42"
    SHA256 = "2.16.840.1.101.3.4.2.1"
    KEY_ITERATIONS = 100_000
    MAC_ITERATIONS = 10_000

    HASHES = { "1.3.14.3.2.26" => "SHA1", "2.16.840.1.101.3.4.2.1" => "SHA256", "2.16.840.1.101.3.4.2.2" => "SHA384",
               "2.16.840.1.101.3.4.2.3" => "SHA512" }.freeze
    CIPHERS = { "2.16.840.1.101.3.4.1.2" => "aes-128-cbc", "2.16.840.1.101.3.4.1.22" => "aes-192-cbc",
                "2.16.840.1.101.3.4.1.42" => "aes-256-cbc", "1.2.840.113549.3.7" => "des-ede3-cbc" }.freeze
    PRFS = { "1.2.840.113549.2.7" => "SHA1", "1.2.840.113549.2.9" => "SHA256", "1.2.840.113549.2.10" => "SHA384",
             "1.2.840.113549.2.11" => "SHA512" }.freeze

    def self.seq(*values) = OpenSSL::ASN1::Sequence(values)
    def self.oid(value) = OpenSSL::ASN1::ObjectId(value)
    def self.oct(value) = OpenSSL::ASN1::OctetString(value)
    def self.int(value) = OpenSSL::ASN1::Integer(value)
    def self.explicit(value) = OpenSSL::ASN1::ASN1Data.new([value], 0, :CONTEXT_SPECIFIC)
    def self.data_info(data) = seq(oid(DATA), explicit(oct(data)))

    def self.iterations(value)
      number = value.to_i
      unless (1..1_000_000).cover?(number)
        raise Error,
          Error.translate("errors.app.p12_iterations",
            default: "PKCS#12 iteration count is outside the supported range.")
      end

      number
    end

    # RFC 7292 Appendix B derives separate key (1), IV (2) and MAC (3) bytes.
    # Ruby OpenSSL exposes PBKDF2, but not the PKCS#12 diversifier-based KDF.
    # Passwords include a UTF-16BE terminator, even when the password is empty.
    def self.derive(password, salt, count, id:, length:, hash:)
      count = iterations(count)
      digest = OpenSSL::Digest.new(hash)
      size = digest.block_length
      pass = password.encode("UTF-16BE").b + "\x00\x00".b
      input = expand_to_blocks(salt, size) + expand_to_blocks(pass, size)
      diversifier = id.chr.b * size
      output = "".b
      while output.bytesize < length
        block = digest.digest(diversifier + input)
        (count - 1).times { block = digest.digest(block) }
        output << block
        # RFC 7292 B.2: add the repeated digest plus one to each input block,
        # modulo the digest block width, before deriving the next output block.
        increment = (block * ((size + block.bytesize - 1) / block.bytesize)).byteslice(0,
          size).unpack1("H*").to_i(16) + 1
        input = input.bytes.each_slice(size).map do |chunk|
          value = (chunk.pack("C*").unpack1("H*").to_i(16) + increment) % (1 << (8 * size))
          [value.to_s(16).rjust(size * 2, "0")].pack("H*")
        end.join.b
      end
      output.byteslice(0, length)
    end

    # Repeat salt/password bytes to an integral number of digest blocks.
    def self.expand_to_blocks(value, size)
      return "".b if value.empty?

      length = size * ((value.bytesize + size - 1) / size)
      (value * ((length + value.bytesize - 1) / value.bytesize)).byteslice(0, length)
    end

    # Verify the MAC before traversing every SafeBag. PKCS12.new exposes only
    # one private key and would silently drop other keys in multi-entry files.
    def self.load(data, password:)
      authenticated = authenticated_contents(data, password)
      result = Codec::Result.new(certificates: [], keys: [])
      OpenSSL::ASN1.decode(authenticated).value.each do |safe|
        plain = safe_contents(safe, password)
        read_bags(OpenSSL::ASN1.decode(plain), result, password, 0)
      end
      result.certificates.uniq!(&:to_der)
      result
    rescue OpenSSL::OpenSSLError, ArgumentError, NoMethodError, TypeError, IndexError
      raise Error,
        Error.translate("errors.app.p12_read",
          default: "PKCS#12 could not be read. Check the format, encryption and password.")
    end

    # Nested SafeContents are bounded independently of the input byte limit.
    def self.read_bags(safe, result, password, depth)
      if depth > 8
        raise Error,
          Error.translate("errors.app.p12_depth", default: "The PKCS#12 structure is nested too deeply.")
      end

      safe.value.each do |bag|
        if result.certificates.size + result.keys.size > 200
          raise Error,
            Error.translate("errors.app.p12_count",
              default: "Too many PKCS#12 entries.")
        end

        value = bag.value[1].value[0]
        case bag.value[0].oid
        when CERT_BAG
          unless value.value[0].oid == X509_CERTIFICATE
            raise Error,
              Error.translate("errors.app.x509_only",
                default: "Only X.509 certificates are supported.")
          end

          result.certificates << OpenSSL::X509::Certificate.new(value.value[1].value[0].value)
        when KEY_BAG then result.keys << OpenSSL::PKey.read(value.to_der)
        when SHROUDED_KEY
          # Bound the KDF cost before handing PKCS#8 decryption to OpenSSL.
          validate_key_iterations(value.value[0])
          result.keys << OpenSSL::PKey.read(value.to_der, password)
        when SAFE_BAG then read_bags(value, result, password, depth + 1)
        else raise Error, Error.translate("errors.app.p12_entry", default: "PKCS#12 contains an unsupported entry.")
        end
      end
    end

    # Keep resource limits when OpenSSL handles an encrypted PKCS#8 key bag.
    def self.validate_key_iterations(algorithm)
      type, params = algorithm.value
      if type.oid == PBES2
        kdf, encryption = params.value
        raise Error, Error.translate("errors.app.pbkdf2_only", default: "Only PBKDF2 is supported.") unless kdf.value[0].oid == PBKDF2

        CIPHERS.fetch(encryption.value[0].oid)
        iterations(kdf.value[1].value[1].value)
      elsif type.oid == PBE_SHA1_3DES
        iterations(params.value[1].value)
      else
        raise Error,
          Error.translate("errors.app.p12_legacy", default: "Unsupported PKCS#12 encryption. Use AES or 3DES.")
      end
    end

    # SafeContents encryption is not exposed by Ruby's PKCS12 API. Use OpenSSL
    # ciphers and PBKDF2; only legacy 3DES needs the PKCS#12-specific KDF above.
    def self.decrypt(algorithm, data, password)
      type, params = algorithm.value
      if type.oid == PBES2
        cipher = pbes2_cipher(params, password)
      elsif type.oid == PBE_SHA1_3DES
        cipher = OpenSSL::Cipher.new("des-ede3-cbc").decrypt
        salt, count = params.value.map(&:value)
        cipher.key = derive(password, salt, count, id: 1, length: cipher.key_len, hash: "SHA1")
        cipher.iv = derive(password, salt, count, id: 2, length: cipher.iv_len, hash: "SHA1")
      else
        raise Error,
          Error.translate("errors.app.p12_legacy",
            default: "This older PKCS#12 encryption is not supported. Please provide an AES or 3DES PFX file.")
      end
      cipher.update(data) + cipher.final
    end

    # Delegate the common single-key export to OpenSSL. The custom bag writer
    # remains necessary for multiple private keys and certificate-only stores.
    def self.dump(entries, password:)
      if entries.one? && entries.first[:key]
        entry = entries.first
        return OpenSSL::PKCS12.create(password, "cert-1", entry.fetch(:key), entry.fetch(:certificate),
          entry.fetch(:chain), "AES-256-CBC", "AES-256-CBC", KEY_ITERATIONS, MAC_ITERATIONS).to_der
      end

      dump_bags(entries, password: password)
    end

    # Preserve all key/certificate associations through localKeyId attributes.
    def self.dump_bags(entries, password:)
      bags = []
      entries.each_with_index do |entry, index|
        certificate, private_key, chain = entry.values_at(:certificate, :key, :chain)
        attributes = bag_attributes(certificate, index)
        if private_key
          algorithm, encrypted = encrypt_key(private_key, password)
          bags << seq(oid(SHROUDED_KEY), explicit(seq(algorithm, oct(encrypted))), attributes)
        end
        [certificate, *chain].each_with_index do |cert, chain_index|
          cert_attributes = chain_index.zero? ? attributes : OpenSSL::ASN1::Set([])
          bags << seq(oid(CERT_BAG), explicit(seq(oid(X509_CERTIFICATE), explicit(oct(cert.to_der)))), cert_attributes)
        end
      end
      safe = seq(data_info(seq(*bags).to_der)).to_der
      salt = OpenSSL::Random.random_bytes(16)
      key = derive(password, salt, MAC_ITERATIONS, id: 3, length: 32, hash: "SHA256")
      mac = OpenSSL::HMAC.digest("SHA256", key, safe)
      seq(int(3), data_info(safe),
        seq(seq(seq(oid(SHA256), OpenSSL::ASN1::Null(nil)), oct(mac)), oct(salt), int(MAC_ITERATIONS))).to_der
    end

    # Return authenticated SafeContents bytes only after checking the stored MAC.
    def self.authenticated_contents(data, password)
      pfx = OpenSSL::ASN1.decode(data).value
      unless pfx[0].value.to_i == 3
        raise Error,
          Error.translate("errors.app.p12_version",
            default: "Only PKCS#12 version 3 is supported.")
      end

      info = pfx[1].value
      unless info[0].oid == DATA && pfx[2]
        raise Error,
          Error.translate("errors.app.p12_integrity_required",
            default: "PKCS#12 requires password-based integrity verification.")
      end

      authenticated = info[1].value[0].value
      mac = pfx[2].value
      hash = HASHES.fetch(mac[0].value[0].value[0].oid) do
        raise Error, Error.translate("errors.app.p12_mac", default: "Unknown PKCS#12 MAC.")
      end
      expected = mac[0].value[1].value
      digest = OpenSSL::Digest.new(hash)
      key = derive(password, mac[1].value, mac[2]&.value || 1, id: 3, length: digest.digest_length, hash: hash)
      actual = OpenSSL::HMAC.digest(hash, key, authenticated)
      unless actual.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(
        actual, expected
      )
        raise Error,
          Error.translate("errors.app.p12_integrity",
            default: "Invalid PKCS#12 password or integrity check.")
      end

      authenticated
    end

    # ContentInfo holds either plain DER or encrypted SafeContents.
    def self.safe_contents(safe, password)
      fields = safe.value
      content = fields[1].value[0]
      case fields[0].oid
      when DATA then content.value
      when ENCRYPTED
        encrypted_info = content.value[1].value
        decrypt(encrypted_info[1], encrypted_info[2].value, password)
      else raise Error, Error.translate("errors.app.p12_content", default: "Unsupported PKCS#12 content.")
      end
    end

    # Decode PBES2 parameters and delegate password derivation to OpenSSL.
    def self.pbes2_cipher(params, password)
      kdf, encryption = params.value
      unless kdf.value[0].oid == PBKDF2
        raise Error,
          Error.translate("errors.app.pbkdf2_only",
            default: "Only PBKDF2 is supported.")
      end

      settings = kdf.value[1].value
      prf = settings.find { |item| item.is_a?(OpenSSL::ASN1::Sequence) }
      hash = prf ? PRFS.fetch(prf.value[0].oid) : "SHA1"
      cipher = OpenSSL::Cipher.new(CIPHERS.fetch(encryption.value[0].oid)).decrypt
      cipher.key = OpenSSL::KDF.pbkdf2_hmac(password, salt: settings[0].value,
        iterations: iterations(settings[1].value), length: cipher.key_len, hash: hash)
      cipher.iv = encryption.value[1].value
      cipher
    end

    # A shared localKeyId associates each certificate with its private key.
    def self.bag_attributes(certificate, index)
      OpenSSL::ASN1::Set([
        seq(oid(FRIENDLY_NAME),
          OpenSSL::ASN1::Set([OpenSSL::ASN1::BMPString("cert-#{index + 1}".encode("UTF-16BE").b)])),
        seq(oid(LOCAL_KEY_ID), OpenSSL::ASN1::Set([oct(Digest::SHA256.digest(certificate.to_der))]))
      ])
    end

    # Explicit PBES2 parameters retain the configured iteration count, which
    # PKey#private_to_der does not accept as an argument.
    def self.encrypt_key(private_key, password)
      salt = OpenSSL::Random.random_bytes(16)
      cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
      cipher.key = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: KEY_ITERATIONS, length: 32,
        hash: "SHA256")
      iv = cipher.random_iv
      encrypted = cipher.update(private_key.private_to_der) + cipher.final
      algorithm = seq(oid(PBES2), seq(
        seq(oid(PBKDF2), seq(oct(salt), int(KEY_ITERATIONS), seq(oid(HMAC_SHA256), OpenSSL::ASN1::Null(nil)))),
        seq(oid(AES256_CBC), oct(iv))
      ))
      [algorithm, encrypted]
    end
  end
end
