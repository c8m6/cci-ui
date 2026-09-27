# frozen_string_literal: true

module CertificateDiagnostics
  module Sources
    # Bounded HTTPS acquisition. Raw artifacts preserve original notices and allow
    # interrupted multi-file acquisitions to resume on a later indexer pass.
    class Download
      attr_reader :verified_at

      def initialize(config, deadline:, http: nil)
        @config = config
        @http = http || Http.new(self, deadline: deadline)
      end

      def get(url, max_age:)
        raise Error, "invalid_url" unless url.start_with?("https://")

        key = "source:#{Digest::SHA256.hexdigest(url)}"
        cached = CertificateDiagnosticCache.find_by(cache_id: key)
        expiry = cached&.source_expires_at(max_age: max_age, timestamp: "fetched_at")
        if expiry && expiry > Time.current
          remember_time(Time.iso8601(cached.metadata.fetch("fetched_at")))
          return cached.payload
        end

        bytes = @http.fetch(url)
        fetched_at = Time.current
        remember_time(fetched_at)
        CertificateDiagnosticCache.find_or_initialize_by(cache_id: key).update!(payload: bytes,
          expires_at: fetched_at + max_age,
          metadata: { "fetched_at" => fetched_at.iso8601, "url" => url, "sha256" => Digest::SHA256.hexdigest(bytes) })
        bytes
      end

      def invalidate(url)
        CertificateDiagnosticCache.where(cache_id: "source:#{Digest::SHA256.hexdigest(url)}").delete_all
      end

      def [](key)
        @config.trust.limits.fetch(key.to_s) { @config[key] }
      end

      # Vendor downloads never inherit the internal PKI responder allowlist.
      def allowed_networks = []
      def http_proxy = @config.http_proxy

      private

      def remember_time(time)
        @verified_at = [@verified_at, time].compact.min
      end
    end
  end
end
