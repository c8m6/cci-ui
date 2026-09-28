# frozen_string_literal: true

require "base64"
require "json"
require "net/http"

module CertificateDiagnostics
  # The only external-evidence transport in gateway mode; no direct fallback.
  class GatewayClient
    def initialize(config, deadline: nil)
      @config = config
      @deadline = deadline
    end

    def fetch(kind, url, body: nil)
      raise Error, "response_too_large" if body && body.bytesize > 16_384

      settings = @config.gateway
      uri = settings.fetch(:url).dup
      uri.path = "/v1/evidence"
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept-Encoding"] = "identity"
      request.body = JSON.generate(kind: kind, url: url, body: body && Base64.strict_encode64(body))
      seconds = [@config[:request_timeout], @deadline ? @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) : Float::INFINITY].min
      raise Error, "deadline" unless seconds.positive?

      Timeout.timeout(seconds, Error, "deadline") { send_request(uri, request, settings) }
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error,
      Net::HTTPExceptions, Net::HTTPBadResponse
      raise Error, "gateway_unavailable"
    end

    private

    def send_request(uri, request, settings)
      http = connection(uri, settings)
      bytes = read_response(http, request)
      { bytes: bytes.fetch(:body), fetched_at: bytes.fetch(:fetched_at) }
    end

    def connection(uri, settings)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = settings.fetch(:ca_file)
      http.cert = OpenSSL::X509::Certificate.new(File.binread(settings.fetch(:client_cert_file)))
      http.key = OpenSSL::PKey.read(File.binread(settings.fetch(:client_key_file)))
      http.open_timeout = @config[:connect_timeout]
      http.read_timeout = http.write_timeout = @config[:request_timeout]
      http.max_retries = 0
      http
    end

    def read_response(http, request)
      bytes = +"".b
      response = http.request(request) do |reply|
        raise Error, "gateway_unavailable" unless reply.is_a?(Net::HTTPSuccess)
        raise Error, "unsupported_encoding" unless [nil, "identity"].include?(reply["content-encoding"])
        raise Error, "response_too_large" if reply["content-length"].to_i > @config[:max_bytes]

        reply.read_body do |chunk|
          raise Error, "response_too_large" if bytes.bytesize + chunk.bytesize > @config[:max_bytes]

          bytes << chunk
        end
      end
      raise Error, "gateway_unavailable" unless Digest::SHA256.hexdigest(bytes) == response["X-CCI-Evidence-SHA256"]

      fetched_at = Time.iso8601(response.fetch("X-CCI-Evidence-Fetched-At"))
      raise Error, "gateway_unavailable" if fetched_at > Time.current + 300

      { body: bytes, fetched_at: fetched_at }
    rescue KeyError, ArgumentError, TypeError
      raise Error, "gateway_unavailable"
    end
  end
end
