require "net/http"
require "uri"
require "json"
require "base64"
require "openssl"

class ConsulConnection
  class Error < StandardError; end
  class Conflict < Error; end
  def initialize(url: ENV.fetch("CONSUL_URL", "http://127.0.0.1:8500"), token: ENV.fetch("CONSUL_TOKEN", ""))
    @base = URI(url)
    raise Error, "Consul benötigt eine HTTP(S)-URL ohne Zugangsdaten." unless %w[http https].include?(@base.scheme) && @base.host && !@base.userinfo
    @token = token
  end
  def request(method, path, body: nil, missing: false)
    uri = @base.dup
    uri.path, uri.query = path.split("?", 2)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 3
    http.read_timeout = 10
    http.write_timeout = 10
    http.ca_file = ENV["CONSUL_CA_FILE"] unless ENV["CONSUL_CA_FILE"].to_s.empty?
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request["X-Consul-Token"] = @token unless @token.empty?
    request["Content-Type"] = "application/json"
    request.body = body if body
    response = http.request(request)
    return nil if missing && response.code == "404"
    raise Conflict, "Gleichzeitige Änderung erkannt. Bitte erneut versuchen." if response.code == "409"
    raise Error, "Consul-Anfrage fehlgeschlagen (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)
    raise Error, "Consul-Ergebnisse durch ACLs eingeschränkt. Token-Konfiguration prüfen." if response["X-Consul-Results-Filtered-By-ACLs"] == "true"
    JSON.parse(response.body)
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError
    raise Error, "Consul ist nicht erreichbar oder lieferte eine ungültige Antwort."
  end
  def path(key) = "/v1/kv/" + key.split("/").map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
  def get(key)
    entry = request("get", path(key) + "?consistent", missing: true)&.first
    entry && { value: Base64.strict_decode64(entry.fetch("Value") || ""), index: entry.fetch("ModifyIndex") }
  end
  def all(prefix)
    Array(request("get", path(prefix) + "?recurse&consistent", missing: true)).map do |entry|
      { key: entry.fetch("Key"), value: Base64.strict_decode64(entry.fetch("Value") || ""), index: entry.fetch("ModifyIndex") }
    end
  end
  # Fetch known public/private paths together without an intermediate round trip.
  def get_many(keys)
    result = transaction(keys.map { |key| { "Verb" => "get", "Key" => key } })
    result.fetch("Results").to_h do |item|
      entry = item.fetch("KV")
      [entry.fetch("Key"), { value: Base64.strict_decode64(entry.fetch("Value") || ""), index: entry.fetch("ModifyIndex") }]
    end
  end
  def transaction(operations)
    raise Error, "Zu viele Änderungen für eine Consul-Transaktion." if operations.size > 64
    request("put", "/v1/txn", body: JSON.generate(operations.map { |op| { "KV" => op } }))
  end
  def self.set(key, value, index: nil)
    value = JSON.generate(value) unless value.is_a?(String)
    raise Error, "Zertifikatseintrag überschreitet das Consul-Limit von 512 KiB." if value.bytesize > 512 * 1024
    result = { "Verb" => index.nil? ? "set" : "cas", "Key" => key, "Value" => Base64.strict_encode64(value) }
    result["Index"] = index unless index.nil?
    result
  end
end
