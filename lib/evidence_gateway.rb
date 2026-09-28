# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "ipaddr"
require "json"
require "openssl"
require "rack"
require "securerandom"
require "time"
require "uri"
require_relative "operational_log"
require_relative "../app/services/certificate_diagnostics/error"
require_relative "../app/services/certificate_diagnostics/http"
require_relative "trust_profile_configuration"

# Narrow acquisition service. TLS and client authentication belong to Nginx.
module EvidenceGateway
  # Validated limits and exact responder allowlists for the standalone process.
  class Configuration
    LIMITS = { "request_timeout" => 10, "connect_timeout" => 3, "max_bytes" => 20_971_520, "redirects" => 3 }.freeze

    attr_reader :refresh_interval, :store_path, :allowed_networks, :targets

    def initialize(environment = ENV)
      @refresh_interval = Integer(environment.fetch("CCI_EVIDENCE_REFRESH_INTERVAL", "86400"), 10)
      raise ArgumentError, "CCI_EVIDENCE_REFRESH_INTERVAL must be positive" unless @refresh_interval.positive?

      @store_path = environment.fetch("CCI_EVIDENCE_STORE_PATH", "/evidence")
      @limits = LIMITS.to_h do |name, default|
        value = Integer(environment.fetch("CCI_EVIDENCE_#{name.upcase}", default.to_s), 10)
        raise ArgumentError, "CCI_EVIDENCE_#{name.upcase} must be positive" unless value.positive?

        [name, value]
      end
      @allowed_networks = environment.fetch("CCI_EVIDENCE_ALLOWED_NETWORKS", "").split(",").reject(&:empty?).map do |cidr|
        IPAddr.new(cidr.strip)
      end
      @targets = Targets.new(environment)
    end

    def [](key) = @limits.fetch(key.to_s)
    def http_proxy = nil
    def gateway? = false
  end

  # Restricts source acquisition to the selected vendor artifacts.
  class Targets
    def initialize(environment)
      profiles = TrustProfileConfiguration.new(environment)
      @chrome = profiles["trust_chrome"]["target"]
      @firefox = profiles["trust_firefox"]["target"].tr(".", "_")
      @crls = url_set(environment, "CCI_EVIDENCE_CRL_URLS")
      @ocsp = url_set(environment, "CCI_EVIDENCE_OCSP_URLS")
      @sources = source_urls
      @preload = @sources.select { |url| preload_source?(environment, url) }.map { |url| ["source", url] } +
                 @crls.map { |url| ["crl", url] }
    end

    attr_reader :preload

    def allowed?(kind, uri)
      return false unless uri.is_a?(URI::HTTP) && uri.hostname && !uri.userinfo && !uri.fragment &&
                          [80, 443].include?(uri.port)

      case kind
      when "source" then source?(uri.to_s)
      when "crl" then @crls.include?(uri.to_s)
      when "ocsp" then @ocsp.include?(uri.to_s)
      else false
      end
    end

    private

    def preload_source?(environment, url)
      checks = {
        "CCI_TRUST_CHROME_ENABLED" => url.include?("/chromium/chromium/"),
        "CCI_TRUST_FIREFOX_ENABLED" => url.include?("/mozilla-firefox/firefox/"),
        "CCI_TRUST_EDGE_ENABLED" => url.include?("Name=Microsoft"),
        "CCI_TRUST_APPLE_ENABLED" => url.include?("/apple-oss-distributions/") || url.include?("Name=Apple"),
        "CCI_TRUST_UBUNTU_ENABLED" => url.include?("archive.ubuntu.com/") || url.include?("keyserver.ubuntu.com/"),
        "CCI_CHROME_POLICY_ENABLED" => url.include?("www.gstatic.com/ct/log_list/")
      }
      checks.any? { |name, matches| matches && %w[true 1].include?(environment.fetch(name, "false").downcase) }
    end

    def url_set(environment, name)
      values = JSON.parse(environment.fetch(name, "[]"))
      raise ArgumentError, "#{name} must be an array of at most 1000 URLs" unless values.is_a?(Array) && values.size <= 1000

      values.each do |url|
        uri = URI.parse(url)
        unless url.is_a?(String) && url.bytesize <= 2048 && uri.is_a?(URI::HTTP) && uri.hostname && !uri.userinfo &&
               !uri.fragment && [80, 443].include?(uri.port)
          raise ArgumentError, "#{name} contains an invalid URL"
        end
      end.uniq
    rescue JSON::ParserError, URI::InvalidURIError, TypeError
      raise ArgumentError, "#{name} must contain valid HTTP(S) URLs"
    end

    def source_urls
      chrome = %w[net/data/ssl/chrome_root_store/root_store.certs
        net/data/ssl/chrome_root_store/additional.certs net/data/ssl/chrome_root_store/root_store.textproto
        net/cert/root_store.proto LICENSE]
      firefox = "https://raw.githubusercontent.com/mozilla-firefox/firefox/FIREFOX_#{@firefox}_RELEASE/security/nss/"
      chrome.map { |path| "https://raw.githubusercontent.com/chromium/chromium/#{@chrome}/#{path}" } +
        %w[TAG-INFO lib/ckfw/builtins/certdata.txt].map { |path| "#{firefox}#{path}" } +
        %w[Microsoft Apple].map do |vendor|
          "https://ccadb.my.salesforce-sites.com/ccadb/Report?Name=#{vendor}TLSServerAuthenticationCSV"
        end +
        ["https://codeload.github.com/apple-oss-distributions/security_certificates/tar.gz/9c061d71693f4b9ccdddea087ff0428755604bf0"] +
        %w[log_list.json log_list.sig log_list_pubkey.pem].map { |name| "https://www.gstatic.com/ct/log_list/v3/#{name}" } +
        %w[dists/noble-updates/InRelease dists/noble-updates/main/binary-amd64/Packages.gz].map do |path|
          "https://archive.ubuntu.com/ubuntu/#{path}"
        end + ["https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF6ECB3762474EDA9D21B7022871920D1991BC93C"]
    end

    def source?(url)
      @sources.include?(url) || url.match?(%r{\Ahttps://archive\.ubuntu\.com/ubuntu/pool/main/c/ca-certificates/[a-zA-Z0-9_.~+-]+\.deb\z})
    end
  end

  # Atomic content-addressed storage keeps source bytes and acquisition time.
  class Store
    MAX_ENTRIES = 1500

    def initialize(path)
      @path = path
      FileUtils.mkdir_p(path)
    end

    def read(kind, url)
      metadata = JSON.parse(File.binread(meta_path(kind, url)))
      return unless metadata["kind"] == kind && metadata["url"] == url

      digest = metadata.fetch("sha256")
      return unless digest.match?(/\A[a-f0-9]{64}\z/)

      bytes = File.binread(File.join(@path, "#{digest}.bin"))
      return unless Digest::SHA256.hexdigest(bytes) == digest

      [bytes, Time.iso8601(metadata.fetch("fetched_at"))]
    rescue Errno::ENOENT, JSON::ParserError, ArgumentError, KeyError
      nil
    end

    def write(kind, url, bytes, fetched_at)
      path = meta_path(kind, url)
      raise CertificateDiagnostics::Error, "cache_full" if !File.exist?(path) && Dir.glob(File.join(@path, "*.json")).size >= MAX_ENTRIES

      digest = Digest::SHA256.hexdigest(bytes)
      atomic(File.join(@path, "#{digest}.bin"), bytes)
      atomic(path, JSON.generate(kind: kind, url: url, sha256: digest, fetched_at: fetched_at.utc.iso8601))
    end

    def entries
      Dir.glob(File.join(@path, "*.json")).filter_map do |path|
        row = JSON.parse(File.binread(path))
        [row.fetch("kind"), row.fetch("url")]
      rescue JSON::ParserError, KeyError
        nil
      end
    end

    private

    def meta_path(kind, url) = File.join(@path, "#{Digest::SHA256.hexdigest("#{kind}\0#{url}")}.json")

    def atomic(path, bytes)
      temp = "#{path}.#{SecureRandom.hex(8)}.tmp"
      File.binwrite(temp, bytes)
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end
  end

  # Rack endpoint for approved source/CRL downloads and on-demand OCSP relay.
  class App
    def initialize(config = Configuration.new, external: nil, schedule: false)
      @config = config
      @store = Store.new(config.store_path)
      @external = external
      @locks = Array.new(64) { Mutex.new }
      start_scheduler if schedule
    end

    def call(env)
      return response(200) if env["PATH_INFO"] == "/up" && env["REQUEST_METHOD"] == "GET"
      return response(404) unless env["PATH_INFO"] == "/v1/evidence"
      return response(405) unless env["REQUEST_METHOD"] == "POST"

      raw = env.fetch("rack.input").read(32_769)
      return response(413) if raw.bytesize > 32_768

      parsed = parse_input(raw)
      return response(parsed) if parsed.is_a?(Integer)

      kind, url, body = parsed

      bytes, fetched_at = acquire(kind, url, body)
      [200, { "content-type" => "application/octet-stream", "cache-control" => "no-store",
              "x-cci-evidence-fetched-at" => fetched_at.utc.iso8601,
              "x-cci-evidence-sha256" => Digest::SHA256.hexdigest(bytes) }, [bytes]]
    rescue JSON::ParserError, URI::InvalidURIError, ArgumentError, TypeError
      response(400)
    rescue CertificateDiagnostics::Error
      response(503)
    end

    def refresh
      (@store.entries + @config.targets.preload).uniq.each do |kind, url|
        next unless @config.targets.allowed?(kind, URI.parse(url))

        acquire(kind, url, nil)
      rescue CertificateDiagnostics::Error, URI::InvalidURIError
        # Keep original bytes and acquisition time for history; retry next cycle.
      end
    end

    private

    def parse_input(raw)
      input = JSON.parse(raw)
      return 400 unless input.is_a?(Hash) && (input.keys - %w[kind url body]).empty?

      kind, url = input.values_at("kind", "url")
      return 400 unless url.is_a?(String) && url.bytesize <= 2048
      return 403 unless @config.targets.allowed?(kind, URI.parse(url))

      body = input["body"] && Base64.strict_decode64(input["body"])
      return 400 if (kind == "ocsp") != !body.nil? || (body && body.bytesize > 16_384)

      [kind, url, body]
    end

    def start_scheduler
      Thread.new do
        loop do
          refresh
          sleep [@config.refresh_interval, 60].min
        rescue StandardError
          # Serve retained bytes with their original timestamp; retry next cycle.
        end
      end
    end

    def response(status) = [status, { "cache-control" => "no-store", "content-length" => "0" }, []]

    def acquire(kind, url, body)
      return external_fetch(kind, url, body) if kind == "ocsp"

      key = "#{kind}\0#{url}"
      lock = @locks[Digest::SHA256.hexdigest(key).to_i(16) % @locks.size]
      lock.synchronize do
        cached = @store.read(kind, url)
        return cached if current?(kind, cached)

        begin
          bytes, fetched_at = external_fetch(kind, url, nil)
          @store.write(kind, url, bytes, fetched_at)
          [bytes, fetched_at]
        rescue CertificateDiagnostics::Error
          raise unless cached

          cached
        end
      end
    end

    def current?(kind, cached)
      return false unless cached

      due = cached.last + @config.refresh_interval
      if kind == "crl"
        next_update = OpenSSL::X509::CRL.new(cached.first).next_update
        due = [due, next_update].compact.min
      end
      due > Time.now
    rescue OpenSSL::OpenSSLError
      due > Time.now
    end

    def external_fetch(kind, url, body)
      return @external.call(kind, url, body) if @external

      policy = ->(uri) { @config.targets.allowed?(kind, uri) }
      http = CertificateDiagnostics::Http.new(@config, target_policy: policy)
      bytes = http.fetch(url, body: body, content_type: body && "application/ocsp-request")
      [bytes, Time.now.utc]
    rescue CertificateDiagnostics::Error => e
      OperationalLog.warn(logger: "cci.evidence", message: "Evidence acquisition failed", kind: kind,
        target_digest: Digest::SHA256.hexdigest(url), reason: e.message)
      raise
    end
  end
end
