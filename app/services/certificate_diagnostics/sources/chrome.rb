# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # One release revision supplies certificates, trust-purpose metadata and schema.
    class Chrome
      def initialize(download, target:, max_age:)
        @download = download
        @target = target
        @max_age = max_age
      end

      def call
        base = "https://raw.githubusercontent.com/chromium/chromium/#{@target}/"
        certs = get("#{base}net/data/ssl/chrome_root_store/root_store.certs")
        certs += get("#{base}net/data/ssl/chrome_root_store/additional.certs")
        text = get("#{base}net/data/ssl/chrome_root_store/root_store.textproto")
        schema = get("#{base}net/cert/root_store.proto")
        notice = get("#{base}LICENSE")
        parsed = TextProto.parse(text)
        raise Error, "unsupported_schema" unless (parsed.keys - %w[trust_anchors additional_certs mtc_anchors version_major]).empty?

        certificates = certs.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).to_h do |pem|
          cert = OpenSSL::X509::Certificate.new(pem)
          [Certificates::Codec.fingerprint(cert), cert.to_pem]
        end
        anchors = Array(parsed["trust_anchors"]) + Array(parsed["additional_certs"]).select { |a| a["tls_trust_anchor"] == [true] }
        roots = anchors.to_h do |anchor|
          fingerprint = anchor.fetch("sha256_hex").sole
          [fingerprint, { "pem" => certificates.fetch(fingerprint), "chrome" => anchor }]
        end
        { "roots" => roots, "release" => "Chrome #{@target}; root store #{parsed.fetch("version_major").sole}",
          "schema" => schema, "schema_sha256" => Digest::SHA256.hexdigest(schema), "notice" => notice,
          "source" => "#{base}net/data/ssl/chrome_root_store/", "scope" => "chrome_baseline" }
      end

      private

      def get(url) = @download.get(url, max_age: @max_age)
    end
  end
end
