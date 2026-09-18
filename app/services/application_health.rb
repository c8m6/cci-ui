require "net/http"
require "json"

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
      client.request("get", client.path(ConsulStore.namespace + "/") + "?keys&consistent", missing: true)
    end
    AreaConfiguration.legacy_paths.each do |area, path|
      probe(failures, "filesystem:#{area}") do
        raise Unavailable, "Inventory directory is not readable: #{path}" unless File.directory?(path) && File.readable?(path) && File.executable?(path)
        Dir.each_child(path) { break }
      end
    end
    probe(failures, "puppetdb") do
      if PuppetdbConfiguration.enabled?
        PuppetdbConfiguration.new
        PuppetdbConnection.new.inventory('nodes[certname] { limit 1 }')
      end
    end
    probe(failures, "oidc") { check_oidc if ENV.fetch("AUTH_MODE", "oidc") == "oidc" }
    failures
  end

  private

  def probe(failures, name)
    yield
  rescue StandardError => error
    failures[name] = error
  end

  def check_oidc
    issuer = ENV.fetch("OIDC_ISSUER")
    uri = URI(issuer.sub(%r{/+\z}, "") + "/.well-known/openid-configuration")
    raise Unavailable, "Invalid OIDC issuer URL" unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 3
    http.read_timeout = 5
    http.max_retries = 0
    response = http.get(uri.request_uri)
    raise Unavailable, "OIDC discovery returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    metadata = JSON.parse(response.body)
    raise Unavailable, "OIDC discovery issuer mismatch" unless metadata.fetch("issuer") == issuer
    %w[authorization_endpoint token_endpoint jwks_uri].each { |key| metadata.fetch(key) }
  end
end
