# frozen_string_literal: true

module CertificateDiagnostics
  # RFC 6962 v1 precertificate SCTs: parse strictly and verify the signed input.
  # No log submissions, live TLS probes or invented external SCT evidence.
  class EmbeddedScts
    SCT_OID = "1.3.6.1.4.1.11129.2.4.2"
    POISON_OID = "1.3.6.1.4.1.11129.2.4.3"
    attr_reader :timestamps, :unverified

    def initialize(certificate, issuer, logs)
      @certificate = certificate
      @issuer = issuer
      @logs = logs
      @timestamps = []
      @unverified = false
      parse
    rescue OpenSSL::OpenSSLError, ArgumentError, TypeError, KeyError, Error
      @unverified = true
    end

    # Length-delimited parsing rejects truncation and trailing bytes.
    class Reader
      def initialize(bytes)
        @bytes = bytes
        @offset = 0
      end

      def take(size)
        raise Error, "sct_unverified" if size.negative? || @offset + size > @bytes.bytesize

        @bytes.byteslice(@offset, size).tap { @offset += size }
      end

      def number(size) = take(size).unpack1({ 1 => "C", 2 => "n", 8 => "Q>" }.fetch(size))
      def vector = take(number(2))
      def done? = @offset == @bytes.bytesize
    end

    private

    def parse
      tbs = OpenSSL::ASN1.decode(@certificate.to_der).value.first
      extensions = tbs.value.find { |value| value.tag_class == :CONTEXT_SPECIFIC && value.tag == 3 }
      return unless extensions

      entries = extensions.value.first.value
      matches = entries.select { |extension| extension.value.first.oid == SCT_OID }
      return if matches.empty?
      raise Error, "sct_unverified" unless matches.size == 1 && entries.none? { |extension| extension.value.first.oid == POISON_OID }

      # The extension value wraps the TLS SCT list in an ASN.1 OCTET STRING.
      encoded = OpenSSL::ASN1.decode(matches.first.value.last.value)
      raise Error, "sct_unverified" unless encoded.is_a?(OpenSSL::ASN1::OctetString)

      outer = Reader.new(encoded.value)
      list = Reader.new(outer.vector)
      raise Error, "sct_unverified" unless outer.done?

      entries.delete(matches.first)
      @tbs = tbs.to_der
      read_list(list)
    end

    def read_list(list)
      count = 0
      until list.done?
        count += 1
        raise Error, "sct_unverified" if count > 128

        verify(list.vector)
      end
    end

    def verify(bytes)
      reader = Reader.new(bytes)
      raise Error, "sct_unverified" unless reader.number(1).zero?

      log = @logs.fetch(Base64.strict_encode64(reader.take(32)))
      milliseconds = reader.number(8)
      extensions = reader.vector
      hash = reader.number(1)
      algorithm = reader.number(1)
      signature = reader.vector
      raise Error, "sct_unverified" unless reader.done? && hash == 4

      key = OpenSSL::PKey.read(Base64.strict_decode64(log.fetch("key")))
      valid_algorithm = (algorithm == 1 && key.is_a?(OpenSSL::PKey::RSA)) || (algorithm == 3 && key.is_a?(OpenSSL::PKey::EC))
      unless valid_algorithm && key.verify("SHA256", signature, signed_input(milliseconds, extensions)) && eligible?(log, milliseconds)
        raise Error, "sct_unverified"
      end

      @timestamps << milliseconds
    rescue OpenSSL::OpenSSLError, ArgumentError, TypeError, KeyError, Error
      @unverified = true
    end

    def signed_input(milliseconds, extensions)
      issuer_hash = Digest::SHA256.digest(@issuer.public_key.public_to_der)
      [0, 0, milliseconds, 1].pack("CCQ>n") + issuer_hash + [@tbs.bytesize].pack("N").byteslice(1, 3) +
        @tbs + [extensions.bytesize].pack("n") + extensions
    end

    def eligible?(log, milliseconds)
      return false if milliseconds > (Time.current.to_r * 1000).to_i

      state, info = log.fetch("state").first
      return false unless %w[qualified usable readonly retired].include?(state)
      return false if state == "retired" && milliseconds >= (Time.iso8601(info.fetch("timestamp")).to_r * 1000).to_i

      period = log["temporal_interval"]
      return true unless period

      @certificate.not_after >= Time.iso8601(period.fetch("start_inclusive")) &&
        @certificate.not_after < Time.iso8601(period.fetch("end_exclusive"))
    end
  end
end
