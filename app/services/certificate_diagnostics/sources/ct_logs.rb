# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # Signed Google CT metadata for offline certificate auditing, not TLS enforcement.
    class CtLogs
      BASE = "https://www.gstatic.com/ct/log_list/v3/"
      KEY_DIGEST = "f1d8b68e50210d8e73d9a3e97f571773c52d7f28c0b1a71beee81d8562e6fd85"
      FIELDS = %w[description key log_id mmd monitoring_url submission_url url state temporal_interval log_type].freeze
      STATES = %w[qualified usable readonly retired pending rejected].freeze

      def initialize(download, target:, max_age:, freshness: max_age)
        @download = download
        @target = target
        @max_age = max_age
        @freshness = freshness
      end

      def call
        bytes = get("log_list.json")
        signature = get("log_list.sig")
        key = get("log_list_pubkey.pem")
        data = verify(bytes, signature, key)
        { "logs" => logs(data), "release" => "Chrome CT v3 list #{data.fetch("version")}",
          "timestamp" => data.fetch("log_list_timestamp"), "source" => "#{BASE}log_list.json",
          "scope" => "chrome_ct_evidence", "notice" => "https://googlechrome.github.io/CertificateTransparency/log_lists.html" }
      rescue Error => e
        if e.message == "source_verification_failed"
          # A daily publication can race separate artifact requests. Do not retain
          # a mismatched pair until tomorrow; the next bounded retry downloads both.
          %w[log_list.json log_list.sig].each { |name| @download.invalidate("#{BASE}#{name}") }
        end
        raise
      end

      def verify(bytes, signature, pem, key_digest: KEY_DIGEST)
        key = OpenSSL::PKey.read(pem)
        unless Digest::SHA256.hexdigest(key.public_to_der) == key_digest && key.verify("SHA256", signature, bytes)
          raise Error, "source_verification_failed"
        end

        data = JSON.parse(bytes)
        raise Error, "unsupported_schema" unless (data.keys - %w[version log_list_timestamp operators]).empty?

        timestamp = Time.iso8601(data.fetch("log_list_timestamp"))
        raise Error, "source_expired" unless timestamp > Time.current - @freshness && timestamp <= Time.current + 300

        data
      end

      private

      def get(name) = @download.get("#{BASE}#{name}", max_age: @max_age)

      def logs(data)
        entries = data.fetch("operators").flat_map { |operator| Array(operator["logs"]) + Array(operator["tiled_logs"]) }
        raise Error, "unsupported_schema" unless entries.size.between?(1, 1000)

        entries.to_h do |entry|
          raise Error, "unsupported_schema" unless (entry.keys - FIELDS).empty?

          key = OpenSSL::PKey.read(Base64.strict_decode64(entry.fetch("key")))
          id = Base64.strict_encode64(Digest::SHA256.digest(key.public_to_der))
          raise Error, "source_verification_failed" unless id == entry.fetch("log_id")

          state = entry.fetch("state")
          raise Error, "unsupported_schema" unless state.size == 1 && STATES.include?(state.keys.first)

          [id, entry]
        end
      end
    end
  end
end
