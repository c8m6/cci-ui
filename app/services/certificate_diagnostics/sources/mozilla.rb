# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # NSS objects are joined by SHA-1 of the actual DER, never display labels.
    class Mozilla
      def initialize(download, target:, max_age:)
        @download = download
        @target = target
        @max_age = max_age
      end

      def call
        tag = "FIREFOX_#{@target.tr(".", "_")}_RELEASE"
        base = "https://raw.githubusercontent.com/mozilla-firefox/firefox/#{tag}/security/nss/"
        version = @download.get("#{base}TAG-INFO", max_age: @max_age).strip
        text = @download.get("#{base}lib/ckfw/builtins/certdata.txt", max_age: @max_age)
        { "roots" => parse(text), "release" => "Firefox #{@target}; #{version}", "source" => base,
          "scope" => "mozilla_baseline", "notice" => text.lines.take_while { |line| line.start_with?("#") || line.strip.empty? }.join }
      end

      def parse(text)
        objects = text.split(/(?=^CKA_CLASS )/).select { |block| block.start_with?("CKA_CLASS ") }.map { |block| attributes(block) }
        trusted = objects.select { |o| o["CKA_CLASS"] == "CKO_NSS_TRUST" && o["CKA_TRUST_SERVER_AUTH"] == "CKT_NSS_TRUSTED_DELEGATOR" }
                         .index_by { |o| o.fetch("CKA_CERT_SHA1_HASH").unpack1("H*") }
        objects.select { |o| o["CKA_CLASS"] == "CKO_CERTIFICATE" }.filter_map do |object|
          der = object.fetch("CKA_VALUE")
          next unless trusted.key?(Digest::SHA1.hexdigest(der))

          cert = OpenSSL::X509::Certificate.new(der)
          cutoff = object["CKA_NSS_SERVER_DISTRUST_AFTER"]
          data = { "pem" => cert.to_pem }
          data["distrust_after"] = Time.strptime(cutoff, "%y%m%d%H%M%SZ").utc.iso8601 if cutoff && cutoff != "CK_FALSE"
          [Certificates::Codec.fingerprint(cert), data]
        end.to_h
      end

      private

      def attributes(block)
        lines = block.lines.each
        result = {}
        loop do
          line = lines.next
          next unless line.start_with?("CKA_")

          key, type, value = line.split(/\s+/, 3)
          if type == "MULTILINE_OCTAL"
            octal = +""
            loop do
              part = lines.next.strip
              break if part == "END"

              raise Error, "unsupported_schema" unless part.match?(/\A(?:\\[0-7]{3})+\z/)

              octal << part.scan(/\\([0-7]{3})/).flatten.map { |number| number.to_i(8) }.pack("C*")
            end
            result[key] = octal
          else
            result[key] = value&.strip
          end
        end
        result
      end
    end
  end
end
