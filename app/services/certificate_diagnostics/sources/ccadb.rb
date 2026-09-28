# frozen_string_literal: true

require "csv"

module CertificateDiagnostics
  module Sources
    # Vendor-specific TLS reports, linked by Microsoft and the CCADB operators.
    # No company roots and no inferred equivalence between Chromium products.
    class Ccadb
      URL = "https://ccadb.my.salesforce-sites.com/ccadb/Report?Name="
      NOTICE = "Common CA Database (CCADB), CDLA-Permissive-2.0; https://www.ccadb.org/rootstores/usage"

      def initialize(download, target:, max_age:)
        @download = download
        @target = target
        @max_age = max_age
      end

      def call
        url = "#{URL}MicrosoftTLSServerAuthenticationCSV"
        roots = report("Microsoft").to_h do |cert, row|
          [Certificates::Codec.fingerprint(cert), microsoft(cert, row)]
        end
        { "roots" => roots, "release" => "Microsoft public TLS program; Edge Windows/macOS 112+",
          "source" => url, "scope" => "microsoft_baseline", "notice" => NOTICE }
      end

      def report(vendor)
        bytes = @download.get("#{URL}#{vendor}TLSServerAuthenticationCSV", max_age: @max_age)
        rows = CSV.parse(bytes, headers: true)
        required = ["SHA-256 Fingerprint", "X.509 Certificate (PEM)", "#{vendor} Status"]
        required += vendor == "Apple" ? ["Apple Applied Constraints"] : microsoft_columns
        raise Error, "unsupported_schema" unless (required - rows.headers).empty?

        rows.filter_map do |row|
          next unless row["#{vendor} Status"] == "Included"

          cert = OpenSSL::X509::Certificate.new(row.fetch("X.509 Certificate (PEM)"))
          unless Certificates::Codec.fingerprint(cert) == row.fetch("SHA-256 Fingerprint").downcase
            raise Error,
              "source_verification_failed"
          end

          [cert, row]
        end
      end

      def apple_constraints(row, fingerprint)
        raw = row["Apple Applied Constraints"].to_s
        return {} if raw.empty?

        raw = "{#{raw}}" if raw.start_with?('"allowed_policies"')
        data = JSON.parse(raw)
        data = { "allowed_policies" => data } if data.is_a?(Array)
        return { "unsupported_policy" => true } unless (data.keys - %w[name hash allowed_policies]).empty?
        return { "unsupported_policy" => true } if data["hash"] && data["hash"].downcase != fingerprint

        { "denied" => !Array(data["allowed_policies"]).include?("Server Authentication") }
      rescue JSON::ParserError, TypeError
        { "unsupported_policy" => true }
      end

      private

      def microsoft_columns
        ["Microsoft Not Before EKU List", "Microsoft Not Before Date", "Microsoft Disallow EKU List",
          "Microsoft Disabled Date", "Microsoft TLD Restriction"]
      end

      def microsoft(cert, row)
        data = { "pem" => cert.to_pem }
        data["denied"] = row["Microsoft Disallow EKU List"].to_s.split(";").include?("Server Authentication")
        if row["Microsoft Not Before EKU List"].to_s.split(";").include?("Server Authentication")
          data["distrust_after"] = parse_date(row.fetch("Microsoft Not Before Date"))
        end
        data["disabled_at"] = parse_date(row["Microsoft Disabled Date"]) if row["Microsoft Disabled Date"].present?
        # TLD restrictions are not reliably structured in this report. Never
        # claim trust for an anchor whose applicability cannot be interpreted.
        data["unsupported_policy"] = true if row["Microsoft TLD Restriction"].present?
        data
      end

      def parse_date(value)
        Time.strptime(value, "%m/%d/%Y").utc.iso8601
      end
    end
  end
end
