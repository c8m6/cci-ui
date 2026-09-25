# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"
require "openssl"
require "securerandom"

# Minimal Consul KV transport with TLS verification and atomic transaction support.
class ConsulConnection
  class Error < StandardError; end
  class Conflict < Error; end

  def initialize(url: ENV.fetch("CONSUL_URL", "http://127.0.0.1:8500"), token: ENV.fetch("CONSUL_TOKEN", ""))
    @base = URI(url)
    raise Error, "Consul requires an HTTP(S) URL without credentials." unless %w[http
      https].include?(@base.scheme) && @base.host && !@base.userinfo

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
    http.ca_file = ENV.fetch("CONSUL_CA_FILE", nil) unless ENV["CONSUL_CA_FILE"].to_s.empty?
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request["X-Consul-Token"] = @token unless @token.empty?
    request["Content-Type"] = "application/json"
    request.body = body if body
    response = http.request(request)
    return nil if missing && response.code == "404"
    raise Conflict, "Concurrent change detected. Please try again." if response.code == "409"
    raise Error, "Consul request failed (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)
    if response["X-Consul-Results-Filtered-By-ACLs"] == "true"
      raise Error,
        "Consul results are filtered by ACLs. Check the token configuration."
    end

    JSON.parse(response.body)
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError
    raise Error, "Consul is unreachable or returned an invalid response."
  end

  def path(key)
    encoded = key.split("/").map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
    "/v1/kv/#{encoded}"
  end

  def get(key)
    entry = request("get", "#{path(key)}?consistent", missing: true)&.first
    entry && { value: Base64.strict_decode64(entry.fetch("Value") || ""), index: entry.fetch("ModifyIndex") }
  end

  def all(prefix)
    Array(request("get", "#{path(prefix)}?recurse&consistent", missing: true)).map do |entry|
      { key: entry.fetch("Key"), value: Base64.strict_decode64(entry.fetch("Value") || ""),
        index: entry.fetch("ModifyIndex") }
    end
  end

  # Fetch known public/private paths together without an intermediate round trip.
  def get_many(keys)
    result = transaction(keys.map { |key| { "Verb" => "get", "Key" => key } })
    result.fetch("Results").to_h do |item|
      entry = item.fetch("KV")
      [entry.fetch("Key"),
        { value: Base64.strict_decode64(entry.fetch("Value") || ""), index: entry.fetch("ModifyIndex") }]
    end
  end

  def transaction(operations)
    raise Error, "Too many changes for one Consul transaction." if operations.size > 64

    writes = operations.reject { |operation| %w[get get-tree check-index check-not-exists].include?(operation["Verb"]) }
    transaction_id = SecureRandom.uuid
    log_transaction(writes, "attempted", transaction_id)
    result = request("put", "/v1/txn", body: JSON.generate(operations.map { |op| { "KV" => op } }))
    log_transaction(writes, "succeeded", transaction_id)
    result
  rescue StandardError => e
    log_transaction(writes || [], e.is_a?(Conflict) ? "rejected" : "unknown", transaction_id)
    raise
  end

  def log_transaction(writes, outcome, transaction_id)
    return unless defined?(OperationalLog)

    writes.each_with_index do |operation, index|
      OperationalLog.emit("consul.write", operation: operation["Verb"], outcome: outcome,
        transaction_id: transaction_id, operation_index: index)
    end
  end

  def self.set(key, value, index: nil)
    value = JSON.generate(value) unless value.is_a?(String)
    raise Error, "Certificate entry exceeds the Consul limit of 512 KiB." if value.bytesize > 512 * 1024

    result = { "Verb" => index.nil? ? "set" : "cas", "Key" => key, "Value" => Base64.strict_encode64(value) }
    result["Index"] = index unless index.nil?
    result
  end
end
