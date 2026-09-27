# frozen_string_literal: true

require "net/http"
require "resolv"
require "timeout"
require "ipaddr"

module CertificateDiagnostics
  # Resolves once, validates every address, and pins the TCP destination while
  # retaining the original hostname for Host, SNI and TLS peer verification.
  class Http
    ALWAYS_BLOCKED = %w[0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fe80::/10 ff00::/8].map { |cidr| IPAddr.new(cidr) }.freeze
    NON_PUBLIC = %w[10.0.0.0/8 100.64.0.0/10 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
      192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 192.88.99.0/24
      fc00::/7 2001::/23 2001:db8::/32 2002::/16 64:ff9b::/96 64:ff9b:1::/48
      100::/64].map { |cidr| IPAddr.new(cidr) }.freeze

    def initialize(config, deadline: nil, resolver: Resolv)
      @config = config
      @deadline = deadline
      @resolver = resolver
    end

    def fetch(url, body: nil, content_type: nil)
      seconds = [@config[:request_timeout], @deadline ? @deadline - monotonic : Float::INFINITY].min
      raise Error, "deadline" unless seconds.positive?

      Timeout.timeout(seconds, Error, "deadline") { redirects(url, body, content_type) }
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      raise Error, "invalid_url"
    rescue SocketError, Resolv::ResolvError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error,
      Net::HTTPExceptions, Net::HTTPBadResponse
      raise Error, "network_error"
    end

    def allowed_address?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv4_mapped?
      return false if ALWAYS_BLOCKED.any? { |range| range.include?(ip) }
      return true if @config.allowed_networks.any? { |range| range.include?(ip) }
      return false if NON_PUBLIC.any? { |range| range.include?(ip) }
      return false if ip.ipv6? && !IPAddr.new("2000::/3").include?(ip)

      true
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def redirects(url, body, content_type)
      (@config[:redirects] + 1).times do |hop|
        uri = URI.parse(url)
        validate_uri!(uri)
        addresses = @resolver.getaddresses(uri.hostname)
        raise Error, "blocked_destination" if addresses.empty? || addresses.any? { |address| !allowed_address?(address) }

        response, bytes = request(uri, addresses.first, body, content_type)
        return bytes if response.is_a?(Net::HTTPSuccess)
        raise Error, "http_error" unless response.is_a?(Net::HTTPRedirection)
        raise Error, "redirect_limit" if hop == @config[:redirects]

        target = URI.join(uri.to_s, response.fetch("location")).to_s
        raise Error, "invalid_url" if uri.scheme == "https" && URI.parse(target).scheme != "https"

        url = target
      end
    end

    def validate_uri!(uri)
      raise Error, "invalid_url" unless %w[http https].include?(uri.scheme) && uri.hostname && !uri.userinfo && !uri.fragment
      raise Error, "invalid_url" unless [80, 443].include?(uri.port)
    end

    def connection(uri, address)
      proxy = @config.http_proxy
      # Plain HTTP uses a pinned absolute-form destination with the original Host.
      # HTTPS CONNECT uses ipaddr, while TLS SNI and verification use uri.hostname.
      host = proxy && uri.scheme == "http" ? address : uri.hostname
      credentials = [proxy&.user, proxy&.password].map { |part| part && URI::DEFAULT_PARSER.unescape(part) }
      http = Net::HTTP.new(host, uri.port, proxy&.hostname, proxy&.port, *credentials)
      http.ipaddr = address
      http.use_ssl = uri.scheme == "https"
      http
    end

    def request(uri, address, body, content_type)
      http = connection(uri, address)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = @config[:connect_timeout]
      http.read_timeout = http.write_timeout = @config[:request_timeout]
      http.max_retries = 0
      request = (body ? Net::HTTP::Post : Net::HTTP::Get).new(uri.request_uri)
      request["Host"] = uri.host + (uri.port == uri.default_port ? "" : ":#{uri.port}")
      request["Accept-Encoding"] = "identity"
      request["Content-Type"] = content_type if content_type
      request.body = body if body
      bytes = +"".b
      response = http.request(request) do |reply|
        raise Error, "unsupported_encoding" unless [nil, "identity"].include?(reply["content-encoding"])
        raise Error, "response_too_large" if reply["content-length"].to_i > @config[:max_bytes]

        reply.read_body do |chunk|
          raise Error, "response_too_large" if bytes.bytesize + chunk.bytesize > @config[:max_bytes]

          bytes << chunk
        end
      end
      [response, bytes]
    end
  end
end
