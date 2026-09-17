require "stringio"
require "openssl"
require "digest"
require "securerandom"

module Certificates
  # JKS v1/v2 wire format. Java's legacy KeyProtector algorithm is required
  # for interoperability; new internal storage uses AES-GCM (Vault).
  class Jks
    MAGIC = 0xfeedfeed
    OID = "1.3.6.1.4.1.42.2.17.1.1"

    def self.password_bytes(password)
      password.encode("UTF-16BE").b
    end

    def self.load(data, password:)
      raise Error, Error.translate("errors.app.jks_incomplete", default: "JKS-Datei ist unvollständig.") if data.bytesize < 32
      body, signature = data.byteslice(0...-20), data.byteslice(-20, 20)
      expected = Digest::SHA1.digest(password_bytes(password) + "Mighty Aphrodite" + body)
      raise Error, Error.translate("errors.app.jks_integrity", default: "JKS-Passwort oder Integritätsprüfung ungültig.") unless OpenSSL.fixed_length_secure_compare(expected, signature)
      reader = new(body)
      raise Error, Error.translate("errors.app.jks_format", default: "Ungültiges JKS-Format.") unless reader.uint == MAGIC
      version = reader.uint
      raise Error, Error.translate("errors.app.jks_version", default: "Nur JKS-Version 1 und 2 werden unterstützt.") unless [1, 2].include?(version)
      certs, keys = [], []
      count = reader.uint
      raise Error, Error.translate("errors.app.jks_count", default: "Zu viele JKS-Einträge.") if count > 10_000
      count.times do
        type = reader.uint
        reader.utf
        reader.read(8)
        case type
        when 1
          encrypted = OpenSSL::ASN1.decode(reader.blob)
          raise Error, Error.translate("errors.app.jks_encryption", default: "Unbekannte JKS-Schlüsselverschlüsselung.") unless encrypted.value[0].value[0].value == OID
          keys << decrypt(encrypted.value[1].value, password)
          chain_count = reader.uint
          raise Error, Error.translate("errors.app.jks_chain", default: "Zu lange JKS-Kette.") if chain_count > 1000
          chain_count.times { certs << reader.certificate(version) }
        when 2
          certs << reader.certificate(version)
        else
          raise Error, Error.translate("errors.app.jks_entry", default: "Unbekannter JKS-Eintrag.")
        end
      end
      raise Error, Error.translate("errors.app.jks_extra", default: "Zusätzliche Daten in JKS-Datei.") unless reader.eof?
      Codec::Result.new(certificates: certs.uniq { |c| c.to_der }, keys: keys)
    rescue EOFError, OpenSSL::OpenSSLError, EncodingError, ArgumentError
      raise Error, Error.translate("errors.app.jks_read", default: "JKS konnte nicht gelesen werden. Store- und Schlüsselpasswort müssen übereinstimmen.")
    end

    def self.dump(entries, password:)
      raise Error, Error.translate("errors.app.password_required", default: "Bitte ein Exportpasswort angeben.") if password.empty?
      entries = entries.flat_map do |entry|
        entry[:key] ? [entry] : [entry, *entry.fetch(:chain).map { |cert| { certificate: cert, key: nil, chain: [] } }]
      end
      data = [MAGIC, 2, entries.size].pack("N3")
      entries.each_with_index do |entry, index|
        cert, key, chain = entry.values_at(:certificate, :key, :chain)
        data << [key ? 1 : 2].pack("N") << utf("cert-#{index + 1}") << [(Time.now.to_f * 1000).to_i].pack("Q>")
        if key
          cipher = encrypt(key, password)
          wrapped = OpenSSL::ASN1::Sequence([
            OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId(OID), OpenSSL::ASN1::Null(nil)]),
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
      data + Digest::SHA1.digest(password_bytes(password) + "Mighty Aphrodite" + data)
    end

    def self.xor_stream(data, password, salt)
      previous = salt
      stream = String.new(encoding: Encoding::BINARY)
      while stream.bytesize < data.bytesize
        previous = Digest::SHA1.digest(password_bytes(password) + previous)
        stream << previous
      end
      data.bytes.zip(stream.bytes).map { |a, b| a ^ b }.pack("C*")
    end

    def self.encrypt(key, password)
      plain = key.private_to_der
      salt = SecureRandom.random_bytes(20)
      salt + xor_stream(plain, password, salt) + Digest::SHA1.digest(password_bytes(password) + plain)
    end

    def self.decrypt(data, password)
      raise Error, Error.translate("errors.app.jks_key", default: "Ungültiger JKS-Schlüssel.") if data.bytesize < 40
      plain = xor_stream(data.byteslice(20...-20), password, data.byteslice(0, 20))
      expected = Digest::SHA1.digest(password_bytes(password) + plain)
      raise Error, Error.translate("errors.app.jks_key_password", default: "JKS-Schlüsselpasswort ungültig.") unless OpenSSL.fixed_length_secure_compare(expected, data.byteslice(-20, 20))
      OpenSSL::PKey.read(plain)
    end

    def self.blob(value) = [value.bytesize].pack("N") + value
    def self.utf(value) = [value.bytesize].pack("n") + value.b # generated aliases are ASCII

    def initialize(data) = @io = StringIO.new(data)
    def read(size)
      raise EOFError if size > @io.size - @io.pos
      @io.read(size) || raise(EOFError)
    end
    def uint = read(4).unpack1("N")
    def blob = read(uint)
    def utf = read(read(2).unpack1("n"))
    def eof? = @io.eof?
    def certificate(version)
      raise Error, Error.translate("errors.app.x509_only", default: "Nur X.509-Zertifikate werden unterstützt.") if version == 2 && utf != "X.509"
      OpenSSL::X509::Certificate.new(blob)
    end
  end
end
