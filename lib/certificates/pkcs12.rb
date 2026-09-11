require "openssl"

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
    HASHES = { "1.3.14.3.2.26" => "SHA1", "2.16.840.1.101.3.4.2.1" => "SHA256", "2.16.840.1.101.3.4.2.2" => "SHA384", "2.16.840.1.101.3.4.2.3" => "SHA512" }.freeze
    CIPHERS = { "2.16.840.1.101.3.4.1.2" => "aes-128-cbc", "2.16.840.1.101.3.4.1.22" => "aes-192-cbc", "2.16.840.1.101.3.4.1.42" => "aes-256-cbc", "1.2.840.113549.3.7" => "des-ede3-cbc" }.freeze
    PRFS = { "1.2.840.113549.2.7" => "SHA1", "1.2.840.113549.2.9" => "SHA256", "1.2.840.113549.2.10" => "SHA384", "1.2.840.113549.2.11" => "SHA512" }.freeze

    def self.seq(*values) = OpenSSL::ASN1::Sequence(values)
    def self.oid(value) = OpenSSL::ASN1::ObjectId(value)
    def self.oct(value) = OpenSSL::ASN1::OctetString(value)
    def self.int(value) = OpenSSL::ASN1::Integer(value)
    def self.explicit(value) = OpenSSL::ASN1::ASN1Data.new([value], 0, :CONTEXT_SPECIFIC)
    def self.data_info(data) = seq(oid(DATA), explicit(oct(data)))
    def self.iterations(value)
      number = value.to_i
      raise Error, "PKCS#12-Iterationszahl außerhalb des unterstützten Bereichs." unless (1..1_000_000).cover?(number)
      number
    end

    def self.derive(password, salt, count, id, length, hash)
      count = iterations(count)
      digest = OpenSSL::Digest.new(hash)
      size = digest.block_length
      pass = password.encode("UTF-16BE").b + "\x00\x00".b
      repeat = ->(value) { value.empty? ? "".b : (value * ((size * ((value.bytesize + size - 1) / size) + value.bytesize - 1) / value.bytesize)).byteslice(0, size * ((value.bytesize + size - 1) / size)) }
      input = repeat.call(salt) + repeat.call(pass)
      diversifier = id.chr.b * size
      output = "".b
      while output.bytesize < length
        block = digest.digest(diversifier + input)
        (count - 1).times { block = digest.digest(block) }
        output << block
        increment = (block * ((size + block.bytesize - 1) / block.bytesize)).byteslice(0, size).unpack1("H*").to_i(16) + 1
        input = input.bytes.each_slice(size).map do |chunk|
          value = (chunk.pack("C*").unpack1("H*").to_i(16) + increment) % (1 << (8 * size))
          [value.to_s(16).rjust(size * 2, "0")].pack("H*")
        end.join.b
      end
      output.byteslice(0, length)
    end

    def self.load(data, password:)
      pfx = OpenSSL::ASN1.decode(data).value
      raise Error, "Nur PKCS#12-Version 3 wird unterstützt." unless pfx[0].value.to_i == 3
      info = pfx[1].value
      raise Error, "PKCS#12 benötigt passwortbasierte Integritätsprüfung." unless info[0].oid == DATA && pfx[2]
      authenticated = info[1].value[0].value
      mac = pfx[2].value
      hash = HASHES.fetch(mac[0].value[0].value[0].oid) { raise Error, "Unbekannter PKCS#12-MAC." }
      expected = mac[0].value[1].value
      digest = OpenSSL::Digest.new(hash)
      key = derive(password, mac[1].value, mac[2]&.value || 1, 3, digest.digest_length, hash)
      actual = OpenSSL::HMAC.digest(hash, key, authenticated)
      raise Error, "PKCS#12-Passwort oder Integritätsprüfung ungültig." unless actual.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(actual, expected)
      result = Codec::Result.new(certificates: [], keys: [])
      OpenSSL::ASN1.decode(authenticated).value.each do |safe|
        fields = safe.value
        content = fields[1].value[0]
        plain = case fields[0].oid
        when DATA then content.value
        when ENCRYPTED
          encrypted_info = content.value[1].value
          decrypt(encrypted_info[1], encrypted_info[2].value, password)
        else raise Error, "Nicht unterstützter PKCS#12-Inhalt."
        end
        read_bags(OpenSSL::ASN1.decode(plain), result, password, 0)
      end
      result.certificates.uniq!(&:to_der)
      result
    rescue OpenSSL::OpenSSLError, ArgumentError, NoMethodError, TypeError, IndexError, KeyError
      raise Error, "PKCS#12 konnte nicht gelesen werden. Format, Verschlüsselung und Passwort prüfen."
    end

    def self.read_bags(safe, result, password, depth)
      raise Error, "PKCS#12-Struktur ist zu tief verschachtelt." if depth > 8
      safe.value.each do |bag|
        raise Error, "Zu viele PKCS#12-Einträge." if result.certificates.size + result.keys.size > 200
        value = bag.value[1].value[0]
        case bag.value[0].oid
        when CERT_BAG
          raise Error, "Nur X.509-Zertifikate werden unterstützt." unless value.value[0].oid == "1.2.840.113549.1.9.22.1"
          result.certificates << OpenSSL::X509::Certificate.new(value.value[1].value[0].value)
        when KEY_BAG then result.keys << OpenSSL::PKey.read(value.to_der)
        when SHROUDED_KEY then result.keys << OpenSSL::PKey.read(decrypt(value.value[0], value.value[1].value, password))
        when SAFE_BAG then read_bags(value, result, password, depth + 1)
        else raise Error, "PKCS#12 enthält einen nicht unterstützten Eintrag."
        end
      end
    end

    def self.decrypt(algorithm, data, password)
      type, params = algorithm.value
      if type.oid == "1.2.840.113549.1.5.13"
        kdf, encryption = params.value
        raise Error, "Nur PBKDF2 wird unterstützt." unless kdf.value[0].oid == "1.2.840.113549.1.5.12"
        settings = kdf.value[1].value
        prf = settings.find { |item| item.is_a?(OpenSSL::ASN1::Sequence) }
        hash = prf ? PRFS.fetch(prf.value[0].oid) : "SHA1"
        cipher = OpenSSL::Cipher.new(CIPHERS.fetch(encryption.value[0].oid)).decrypt
        cipher.key = OpenSSL::KDF.pbkdf2_hmac(password, salt: settings[0].value, iterations: iterations(settings[1].value), length: cipher.key_len, hash: hash)
        cipher.iv = encryption.value[1].value
      elsif type.oid == "1.2.840.113549.1.12.1.3"
        cipher = OpenSSL::Cipher.new("des-ede3-cbc").decrypt
        salt, count = params.value.map(&:value)
        cipher.key = derive(password, salt, count, 1, cipher.key_len, "SHA1")
        cipher.iv = derive(password, salt, count, 2, cipher.iv_len, "SHA1")
      else
        raise Error, "Diese ältere PKCS#12-Verschlüsselung wird nicht unterstützt. Bitte als AES- oder 3DES-PFX bereitstellen."
      end
      cipher.update(data) + cipher.final
    end

    def self.dump(entries, password:)
      bags = []
      entries.each_with_index do |entry, index|
        certificate, private_key, chain = entry.values_at(:certificate, :key, :chain)
        attributes = OpenSSL::ASN1::Set([
          seq(oid("1.2.840.113549.1.9.20"), OpenSSL::ASN1::Set([OpenSSL::ASN1::BMPString("cert-#{index + 1}".encode("UTF-16BE").b)])),
          seq(oid("1.2.840.113549.1.9.21"), OpenSSL::ASN1::Set([oct(Digest::SHA256.digest(certificate.to_der))]))
        ])
        if private_key
          salt = OpenSSL::Random.random_bytes(16)
          cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
          cipher.key = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: 100_000, length: 32, hash: "SHA256")
          iv = cipher.random_iv
          encrypted = cipher.update(private_key.private_to_der) + cipher.final
          algorithm = seq(oid("1.2.840.113549.1.5.13"), seq(
            seq(oid("1.2.840.113549.1.5.12"), seq(oct(salt), int(100_000), seq(oid("1.2.840.113549.2.9"), OpenSSL::ASN1::Null(nil)))),
            seq(oid("2.16.840.1.101.3.4.1.42"), oct(iv))))
          bags << seq(oid(SHROUDED_KEY), explicit(seq(algorithm, oct(encrypted))), attributes)
        end
        [certificate, *chain].each_with_index do |cert, chain_index|
          cert_attributes = chain_index.zero? ? attributes : OpenSSL::ASN1::Set([])
          bags << seq(oid(CERT_BAG), explicit(seq(oid("1.2.840.113549.1.9.22.1"), explicit(oct(cert.to_der)))), cert_attributes)
        end
      end
      safe = seq(data_info(seq(*bags).to_der)).to_der
      salt = OpenSSL::Random.random_bytes(16)
      key = derive(password, salt, 10_000, 3, 32, "SHA256")
      mac = OpenSSL::HMAC.digest("SHA256", key, safe)
      seq(int(3), data_info(safe), seq(seq(seq(oid("2.16.840.1.101.3.4.2.1"), OpenSSL::ASN1::Null(nil)), oct(mac)), oct(salt), int(10_000))).to_der
    end
  end
end
