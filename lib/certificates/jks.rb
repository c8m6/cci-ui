# frozen_string_literal: true

require "stringio"
require "openssl"

module Certificates
  # JKS v1/v2 wire format. Java's legacy KeyProtector algorithm is required
  # for interoperability; new internal storage uses AES-GCM (Vault).
  # Ruby OpenSSL has no JKS reader or Java KeyProtector cipher. Keep the wire
  # format here and delegate hashes, randomness, ASN.1 and key parsing to OpenSSL.
  class Jks
    MAGIC = 0xfeedfeed
    KEY_PROTECTOR_OID = "1.3.6.1.4.1.42.2.17.1.1"

    # JKS uses UTF-16BE code units without the PKCS#12 trailing NUL.
    def self.password_bytes(password)
      password.encode("UTF-16BE").b
    end

    # Authenticate the entire store before reading entry lengths or private keys.
    def self.load(data, password:)
      reader, version = authenticated_reader(data, password)
      certs = []
      keys = []
      count = reader.uint
      raise Error, Error.translate("errors.app.jks_count", default: "Too many JKS entries.") if count > 10_000

      count.times do
        type = reader.uint
        reader.utf
        reader.read(8)
        case type
        when 1
          read_key_entry(reader, version, password, certs, keys)
        when 2
          certs << reader.certificate(version)
        else
          raise Error, Error.translate("errors.app.jks_entry", default: "Unknown JKS entry.")
        end
      end
      unless reader.eof?
        raise Error,
          Error.translate("errors.app.jks_extra",
            default: "Unexpected additional data in the JKS file.")
      end

      Codec::Result.new(certificates: certs.uniq(&:to_der), keys: keys)
    rescue EOFError, OpenSSL::OpenSSLError, EncodingError, ArgumentError
      raise Error,
        Error.translate("errors.app.jks_read",
          default: "JKS could not be read. Store and key passwords must match.")
    end

    # Write version 2 entries, including certificate types and millisecond timestamps.
    def self.dump(entries, password:)
      if password.empty?
        raise Error,
          Error.translate("errors.app.password_required",
            default: "Please enter an export password.")
      end

      entries = expand_trust_entries(entries)
      data = [MAGIC, 2, entries.size].pack("N3")
      entries.each_with_index do |entry, index|
        cert, key, chain = entry.values_at(:certificate, :key, :chain)
        data << [key ? 1 : 2].pack("N") << utf("cert-#{index + 1}") << [(Time.now.to_f * 1000).to_i].pack("Q>")
        if key
          cipher = encrypt(key, password)
          wrapped = OpenSSL::ASN1::Sequence([
            OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId(KEY_PROTECTOR_OID), OpenSSL::ASN1::Null(nil)]),
            OpenSSL::ASN1::OctetString(cipher)
          ]).to_der
          data << blob(wrapped)
          certificates = [cert, *chain]
          data << [certificates.size].pack("N")
          certificates.each { |c| data << utf("X.509") << blob(c.to_der) }
        else
          data << utf("X.509") << blob(cert.to_der)
        end
      end
      data + OpenSSL::Digest.digest("SHA1", "#{password_bytes(password)}Mighty Aphrodite#{data}")
    end

    # Java KeyProtector chains SHA-1(password || previous digest) into a mask.
    # This legacy compatibility algorithm is not suitable for new storage formats.
    def self.xor_stream(data, password, salt)
      previous = salt
      stream = String.new(encoding: Encoding::BINARY)
      while stream.bytesize < data.bytesize
        previous = OpenSSL::Digest::SHA1.digest(password_bytes(password) + previous)
        stream << previous
      end
      data.bytes.zip(stream.bytes).map { |a, b| a ^ b }.pack("C*")
    end

    # Wrap PKCS#8 DER with a random 20-byte salt and a password-bound checksum.
    def self.encrypt(key, password)
      plain = key.private_to_der
      salt = OpenSSL::Random.random_bytes(20)
      salt + xor_stream(plain, password, salt) + OpenSSL::Digest::SHA1.digest(password_bytes(password) + plain)
    end

    # Recover PKCS#8 bytes and verify the checksum before parsing the private key.
    def self.decrypt(data, password)
      raise Error, Error.translate("errors.app.jks_key", default: "Invalid JKS key.") if data.bytesize < 40

      plain = xor_stream(data.byteslice(20...-20), password, data.byteslice(0, 20))
      expected = OpenSSL::Digest::SHA1.digest(password_bytes(password) + plain)
      unless OpenSSL.fixed_length_secure_compare(
        expected, data.byteslice(-20, 20)
      )
        raise Error,
          Error.translate("errors.app.jks_key_password",
            default: "Invalid JKS key password.")
      end

      OpenSSL::PKey.read(plain)
    end

    def self.blob(value) = [value.bytesize].pack("N") + value
    # generated aliases are ASCII
    def self.utf(value) = [value.bytesize].pack("n") + value.b

    def initialize(data) = @io = StringIO.new(data)

    # Reject declared lengths beyond the remaining buffer before allocating.
    def read(size)
      raise EOFError if size > @io.size - @io.pos

      @io.read(size) || raise(EOFError)
    end

    def uint = read(4).unpack1("N")
    def blob = read(uint)
    # Imported aliases are skipped as raw modified-UTF bytes, not displayed.
    def utf = read(read(2).unpack1("n"))
    def eof? = @io.eof?

    def certificate(version)
      if version == 2 && utf != "X.509"
        raise Error,
          Error.translate("errors.app.x509_only",
            default: "Only X.509 certificates are supported.")
      end

      OpenSSL::X509::Certificate.new(blob)
    end

    # Validate the store digest and version before trusting entry counts.
    def self.authenticated_reader(data, password)
      if data.bytesize < 32
        raise Error,
          Error.translate("errors.app.jks_incomplete", default: "The JKS file is incomplete.")
      end

      body = data.byteslice(0...-20)
      signature = data.byteslice(-20, 20)
      expected = OpenSSL::Digest.digest("SHA1", "#{password_bytes(password)}Mighty Aphrodite#{body}")
      unless OpenSSL.fixed_length_secure_compare(
        expected, signature
      )
        raise Error,
          Error.translate("errors.app.jks_integrity",
            default: "Invalid JKS password or integrity check.")
      end

      reader = new(body)
      raise Error, Error.translate("errors.app.jks_format", default: "Invalid JKS format.") unless reader.uint == MAGIC

      version = reader.uint
      unless [
        1, 2
      ].include?(version)
        raise Error,
          Error.translate("errors.app.jks_version", default: "Only JKS versions 1 and 2 are supported.")
      end

      [reader, version]
    end

    # Key entries contain encrypted PKCS#8 followed by their certificate chain.
    def self.read_key_entry(reader, version, password, certs, keys)
      encrypted = OpenSSL::ASN1.decode(reader.blob)
      unless encrypted.value[0].value[0].value == KEY_PROTECTOR_OID
        raise Error,
          Error.translate("errors.app.jks_encryption",
            default: "Unknown JKS key encryption.")
      end

      keys << decrypt(encrypted.value[1].value, password)
      chain_count = reader.uint
      if chain_count > 1000
        raise Error,
          Error.translate("errors.app.jks_chain", default: "The JKS chain is too long.")
      end

      chain_count.times { certs << reader.certificate(version) }
    end

    # Trusted certificates have no chain slot, so export each CA as its own entry.
    def self.expand_trust_entries(entries)
      entries.flat_map do |entry|
        entry[:key] ? [entry] : [entry, *entry.fetch(:chain).map { |cert| { certificate: cert, key: nil, chain: [] } }]
      end
    end
  end
end
