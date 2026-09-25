# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

# Reads complete PuppetDB snapshots with TLS, size limits and record-count verification.
class PuppetdbConnection
  class Error < StandardError; end

  attr_reader :last_http_status

  def initialize(environment: ENV)
    @environment = environment
    @uri = URI(environment.fetch("PUPPETDB_URL", ""))
    unless %w[http https].include?(@uri.scheme) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
      raise Error, "PUPPETDB_URL must be an HTTP(S) base URL without credentials, query or fragment."
    end

    @uri.path = "#{@uri.path.sub(%r{/+\z}, "")}/pdb/query/v4"
    @uri.query = "include_total=true"
    @timeout = positive_integer("PUPPETDB_TIMEOUT", 30)
    @max_bytes = positive_integer("PUPPETDB_MAX_RESPONSE_BYTES", 50 * 1024 * 1024)
    @token = environment.fetch("PUPPETDB_TOKEN", "")
    @cert_file = environment.fetch("PUPPETDB_CLIENT_CERT_FILE", "")
    @key_file = environment.fetch("PUPPETDB_CLIENT_KEY_FILE", "")
    raise Error, "PuppetDB requires both a client certificate and its private key." if @cert_file.empty? != @key_file.empty?
    raise Error, "PuppetDB credentials require HTTPS." if @uri.scheme != "https" && (!@token.empty? || !@cert_file.empty?)
  rescue URI::InvalidURIError
    raise Error, "PUPPETDB_URL is invalid."
  end

  # Fetch the complete result in one request so changing factsets cannot move
  # hosts between offset pages. Never publish a truncated or partial response.
  def inventory(query, verify_total: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    uri = query_uri(verify_total)
    fields = { system: "puppetdb", operation: "inventory_query", http_method: "POST",
               endpoint: safe_endpoint(uri) }
    OperationalLog.debug(logger: "cci.puppetdb", message: "PuppetDB query started", **fields)
    body, total = perform_request(configured_http, build_request(uri, query), verify_total)
    rows = parse_rows(body, total)
    OperationalLog.debug(logger: "cci.puppetdb", message: "PuppetDB query completed", **fields,
      http_status: @last_http_status, resource_count: rows.size, duration_ms: elapsed_ms(started),
      result: rows.empty? ? "no_data" : "data")
    rows
  rescue Error => e
    OperationalLog.failure(logger: "cci.puppetdb", message: "PuppetDB response could not be used",
      error: e, level: :warn, **(fields || {}), http_status: @last_http_status,
      duration_ms: started && elapsed_ms(started),
      result: @last_http_status && @last_http_status != 200 ? "http_error" : "unprocessable_response")
    raise
  rescue JSON::ParserError => e
    safe_error = Error.new("PuppetDB returned invalid JSON. Host assignments are preserved.")
    safe_error.set_backtrace(e.backtrace)
    OperationalLog.failure(logger: "cci.puppetdb", message: "PuppetDB response could not be used",
      error: safe_error, level: :warn, **(fields || {}), http_status: @last_http_status,
      duration_ms: started && elapsed_ms(started), result: "unprocessable_response",
      upstream_error_type: e.class.name)
    raise safe_error
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::OpenSSLError,
    Net::HTTPBadResponse => e
    safe_error = Error.new("PuppetDB is unreachable or returned an invalid response. Check TLS and connectivity.")
    safe_error.set_backtrace(e.backtrace)
    OperationalLog.failure(logger: "cci.puppetdb", message: "PuppetDB connection failed",
      error: safe_error, level: :warn, **(fields || {}), http_status: @last_http_status,
      duration_ms: started && elapsed_ms(started), result: "unreachable",
      upstream_error_type: e.class.name, diagnostic_reasons: OperationalLog.reasons(e))
    raise safe_error
  end

  private

  def query_uri(verify_total)
    uri = @uri.dup
    uri.query = nil unless verify_total
    uri
  end

  def build_request(uri, query)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request["X-Authentication"] = @token unless @token.empty?
    request["X-Request-ID"] = LogContext.correlation_id if LogContext.correlation_id
    request.body = JSON.generate(query: query)
    request
  end

  def perform_request(http, request, verify_total)
    body = +""
    total = nil
    http.request(request) do |response|
      @last_http_status = response.code.to_i
      raise Error, "PuppetDB request failed (HTTP #{response.code})." unless response.code == "200"

      total = response["X-Records"] if verify_total
      response.read_body do |chunk|
        raise Error, "PuppetDB response exceeds PUPPETDB_MAX_RESPONSE_BYTES." if body.bytesize + chunk.bytesize > @max_bytes

        body << chunk
      end
    end
    [body, total]
  end

  def parse_rows(body, total)
    rows = JSON.parse(body)
    raise Error, "PuppetDB must return a JSON array of host inventories." unless rows.is_a?(Array)
    if total && (!total.match?(/\A\d+\z/) || total.to_i != rows.size)
      raise Error, "PuppetDB returned an incomplete result. Host assignments are preserved."
    end

    rows
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end

  def safe_endpoint(uri)
    URI::Generic.build(scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path).to_s
  end

  def positive_integer(name, default)
    value = Integer(@environment.fetch(name, default).to_s, 10)
    raise ArgumentError unless value.positive?

    value
  rescue ArgumentError, TypeError
    raise Error, "#{name} must be a positive integer."
  end

  # Disable retries and verify server identity and the optional client key.
  def configured_http
    http = Net::HTTP.new(@uri.host, @uri.port, nil)
    http.use_ssl = @uri.scheme == "https"
    http.open_timeout = [@timeout, 5].min
    http.read_timeout = @timeout
    http.write_timeout = @timeout
    http.max_retries = 0
    if http.use_ssl?
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true
      ca_file = @environment.fetch("PUPPETDB_CA_FILE", "")
      http.ca_file = ca_file unless ca_file.empty?
      unless @cert_file.empty?
        http.cert = OpenSSL::X509::Certificate.new(File.binread(@cert_file))
        http.key = OpenSSL::PKey.read(File.binread(@key_file), "")
      end
    end
    http
  end
end
