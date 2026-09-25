# frozen_string_literal: true

require "net/http"
require "json"

# Checks configured dependencies and reports failures without response bodies or secrets.
class ApplicationHealth
  class Unavailable < StandardError; end

  def self.check
    new.check
  end

  def check
    failures = {}
    probe(failures, "postgresql") do
      ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value("SELECT 1") }
    end
    probe(failures, "consul") do
      client = ConsulStore.client
      client.request("get", "#{client.path("#{ConsulStore.namespace}/")}?keys&consistent", missing: true)
    end
    AreaConfiguration.legacy_paths.each do |area, path|
      probe(failures, "filesystem:#{area}") do
        unless File.directory?(path) && File.readable?(path) && File.executable?(path)
          raise Unavailable,
            "Inventory directory is not readable: #{path}"
        end

        Dir.open(path, &:read)
      end
    end
    probe(failures, "puppetdb") do
      if PuppetdbConfiguration.enabled?
        PuppetdbConfiguration.new
        PuppetdbConnection.new.inventory("nodes[certname] { limit 1 }", verify_total: false)
      end
    end
    probe(failures, "oidc") { check_oidc if ENV.fetch("AUTH_MODE", "oidc") == "oidc" }
    failures
  end

  private

  def probe(failures, name)
    yield
  rescue StandardError => e
    failures[name] = e
  end

  def check_oidc
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    issuer = ENV.fetch("OIDC_ISSUER")
    uri = oidc_uri(issuer)
    fields = { system: "keycloak", operation: "oidc_discovery_health", http_method: "GET",
               endpoint: safe_endpoint(uri) }
    OperationalLog.debug(logger: "cci.keycloak", message: "Keycloak discovery health request started", **fields)
    response = oidc_response(uri)
    result = response.is_a?(Net::HTTPSuccess) ? "success" : "http_error"
    OperationalLog.debug(logger: "cci.keycloak", message: "Keycloak discovery health request completed", **fields,
      http_status: response.code.to_i, duration_ms: elapsed_ms(started), result: result)
    validate_oidc_response(response, issuer)
  rescue StandardError => e
    safe_error = Unavailable.new("Keycloak discovery health check failed")
    safe_error.set_backtrace(e.backtrace)
    OperationalLog.failure(logger: "cci.keycloak", message: "Keycloak discovery health check failed",
      error: safe_error, level: :debug, **(fields || {}), duration_ms: started && elapsed_ms(started),
      upstream_error_type: e.class.name, diagnostic_reasons: OperationalLog.reasons(e))
    raise
  end

  def oidc_uri(issuer)
    uri = URI("#{issuer.sub(%r{/+\z}, "")}/.well-known/openid-configuration")
    raise Unavailable, "Invalid OIDC issuer URL" unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo

    uri
  end

  def oidc_response(uri)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 3
    http.read_timeout = 5
    http.max_retries = 0
    request = Net::HTTP::Get.new(uri)
    request["X-Request-ID"] = LogContext.correlation_id if LogContext.correlation_id
    http.request(request)
  end

  def validate_oidc_response(response, issuer)
    raise Unavailable, "OIDC discovery returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    metadata = JSON.parse(response.body)
    raise Unavailable, "OIDC discovery issuer mismatch" unless metadata.fetch("issuer") == issuer

    %w[authorization_endpoint token_endpoint jwks_uri].each { |key| metadata.fetch(key) }
  end

  def safe_endpoint(uri)
    URI::Generic.build(scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path).to_s
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
end
