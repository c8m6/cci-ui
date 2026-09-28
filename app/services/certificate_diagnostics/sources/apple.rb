# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # Exact macOS 15 release roots, combined with Apple's TLS-purpose metadata.
    # The archive remains a public data artifact, not application source code.
    class Apple
      REVISION = "9c061d71693f4b9ccdddea087ff0428755604bf0"
      VERSION = "2024051500"
      URL = "https://codeload.github.com/apple-oss-distributions/security_certificates/tar.gz/#{REVISION}".freeze

      def initialize(download, target:, max_age:, archive:)
        @download = download
        @target = target
        @max_age = max_age
        @archive = archive
      end

      def call
        bytes = @download.get(URL, max_age: @max_age)
        files = @archive.tar(@archive.gzip(bytes)) do |name|
          name.include?("/certificates/roots/") || name.end_with?("/config/AssetVersion.plist", "/README.txt")
        end
        version = files.find { |path, _| path.end_with?("/config/AssetVersion.plist") }&.last
        raise Error, "source_verification_failed" unless version&.match?(%r{<integer>#{VERSION}</integer>})

        report = Ccadb.new(@download, target: @target, max_age: @max_age)
        metadata = report.report("Apple").to_h { |cert, row| [Certificates::Codec.fingerprint(cert), row] }
        roots = files.filter_map do |path, der|
          next unless path.include?("/certificates/roots/") && path.match?(/\.(?:cer|crt|der|pem)\z/i)

          cert = OpenSSL::X509::Certificate.new(der)
          fingerprint = Certificates::Codec.fingerprint(cert)
          row = metadata[fingerprint]
          constraints = row ? report.apple_constraints(row, fingerprint) : { "unsupported_policy" => true }
          [fingerprint, constraints.merge("pem" => cert.to_pem)]
        end.to_h
        { "roots" => roots, "release" => "macOS 15 / Safari; root store #{VERSION}; current Apple TLS metadata",
          "source" => URL, "scope" => "apple_baseline", "notice" => Ccadb::NOTICE,
          "revision" => REVISION }
      end
    end
  end
end
