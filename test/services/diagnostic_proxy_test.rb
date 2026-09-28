# frozen_string_literal: true

require "test_helper"
require "socket"

class DiagnosticProxyTest < ActiveSupport::TestCase
  class Client < CertificateDiagnostics::Http
    attr_accessor :store

    def connection(uri, address)
      super.tap { |http| http.cert_store = store if store }
    end
  end

  Resolver = Struct.new(:addresses) do
    def getaddresses(*) = addresses
  end

  def read_request(socket)
    line = socket.gets
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.strip
    end
    [line, headers, socket.read(headers.fetch("content-length", "0").to_i)]
  end

  def with_proxy(tls: nil, response: nil)
    server = TCPServer.new("127.0.0.1", 0)
    captured = Queue.new
    thread = Thread.new do
      socket = server.accept
      captured << read_request(socket)
      if tls
        socket.write("HTTP/1.1 200 Connection established\r\n\r\n")
        socket = OpenSSL::SSL::SSLSocket.new(socket, tls).tap { |ssl| ssl.sync_close = true }
        socket.accept
        captured << read_request(socket)
      end
      socket.write(response || "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    rescue OpenSSL::SSL::SSLError, Errno::EPIPE, Errno::ECONNRESET
      # Expected for rejected TLS handshakes.
    ensure
      socket&.close
    end
    thread.report_on_exception = false
    yield "http://test%40user:p%3Ass@127.0.0.1:#{server.addr[1]}", captured
  ensure
    server&.close
    if thread
      thread.join(2) || thread.kill
      thread.value
    end
  end

  def client(proxy, addresses = ["8.8.8.8"], **settings)
    config = CertificateDiagnosticsConfiguration.new({ "CCI_DIAGNOSTICS_HTTP_PROXY" => proxy }.merge(settings))
    Client.new(config, resolver: Resolver.new(addresses))
  end

  test "HTTP proxy pins absolute URI retains Host and sends encoded credentials and POST body" do
    with_proxy do |url, captured|
      result = client(url).fetch("http://responder.example.test/check?one=2", body: "ocsp", content_type: "application/ocsp-request")
      assert_equal "ok", result
      line, headers, body = captured.pop
      assert_equal "POST http://8.8.8.8/check?one=2 HTTP/1.1\r\n", line
      assert_equal "responder.example.test", headers["host"]
      assert_equal "Basic #{Base64.strict_encode64("test@user:p:ss")}", headers["proxy-authorization"]
      assert_equal "application/ocsp-request", headers["content-type"]
      assert_equal "ocsp", body
    end
  end

  test "HTTPS CONNECT pins IP while TLS verifies the original hostname and keeps proxy credentials out of tunnel" do
    root, key = issue(name: "Synthetic Proxy CA", ca: true)
    leaf, leaf_key = issue(issuer: root, issuer_key: key)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = leaf
    context.key = leaf_key
    names = []
    context.servername_cb = proc do |_ssl, hostname|
      names << hostname
      nil
    end
    with_proxy(tls: context) do |url, captured|
      http = client(url)
      http.store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(root) }
      assert_equal "ok", http.fetch("https://portal.example.test/path")
      connect, headers, = captured.pop
      assert_equal "CONNECT 8.8.8.8:443 HTTP/1.1\r\n", connect
      assert headers["proxy-authorization"]
      line, headers, = captured.pop
      assert_equal "GET /path HTTP/1.1\r\n", line
      assert_equal "portal.example.test", headers["host"]
      assert_nil headers["proxy-authorization"]
      assert_equal ["portal.example.test"], names
    end
    ["portal.example.test", "wrong.example.test"].each do |host|
      with_proxy(tls: context) do |url, _|
        http = client(url)
        http.store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(root) } if host.start_with?("wrong")
        error = assert_raises(CertificateDiagnostics::Error) { http.fetch("https://#{host}/") }
        assert_equal "network_error", error.message
      end
    end
  end

  test "blocked DNS and redirects are rejected before proxy can bypass destination policy" do
    ["127.0.0.1", "169.254.169.254", "10.0.0.1"].each do |address|
      error = assert_raises(CertificateDiagnostics::Error) { client("http://127.0.0.1:1", [address]).fetch("http://blocked.test/") }
      assert_equal "blocked_destination", error.message
    end
    resolver = Resolver.new(["8.8.8.8"])
    def resolver.getaddresses(host) = host == "portal.example.test" ? ["8.8.8.8"] : ["127.0.0.1"]
    redirect = "HTTP/1.1 302 Found\r\nLocation: http://blocked.test/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    with_proxy(response: redirect) do |url, _|
      config = CertificateDiagnosticsConfiguration.new("CCI_DIAGNOSTICS_HTTP_PROXY" => url)
      error = assert_raises(CertificateDiagnostics::Error) do
        CertificateDiagnostics::Http.new(config, resolver: resolver).fetch("http://portal.example.test/")
      end
      assert_equal "blocked_destination", error.message
    end
  end

  test "proxy failures are sanitized and response size limits still apply" do
    ["HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n"].each do |response|
      with_proxy(response: response) do |url, _|
        error = assert_raises(CertificateDiagnostics::Error) { client(url).fetch("http://portal.example.test/") }
        assert_includes %w[http_error response_too_large], error.message
        assert_not_includes error.message, "p:ss"
      end
    end
    with_proxy(response: "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n") do |url, _|
      error = assert_raises(CertificateDiagnostics::Error) { client(url).fetch("https://portal.example.test/") }
      assert_equal "network_error", error.message
    end
  end

  test "configuration defaults to direct and vendor downloads inherit only explicit proxy" do
    config = CertificateDiagnosticsConfiguration.new("HTTP_PROXY" => "http://ambient.test:1234")
    assert_nil config.http_proxy
    assert_not Client.new(config).send(:connection, URI("http://portal.example.test"), "8.8.8.8").proxy?
    ["https://proxy.test", "http://proxy.test/path", "http://proxy.test?secret=yes",
      "http://proxy.test#secret", "http://proxy.test:0", "http://user:secret\n@proxy.test"].each do |url|
      error = assert_raises(ArgumentError) { CertificateDiagnosticsConfiguration.new("CCI_DIAGNOSTICS_HTTP_PROXY" => url) }
      assert_not_includes error.message, "secret"
      assert_nil error.cause
    end
    config = CertificateDiagnosticsConfiguration.new("CCI_DIAGNOSTICS_HTTP_PROXY" => "http://proxy.test:3128",
      "CCI_DIAGNOSTICS_ALLOWED_NETWORKS" => "10.0.0.0/8")
    download = CertificateDiagnostics::Sources::Download.new(config, deadline: 1)
    assert_equal config.http_proxy, download.http_proxy
    assert_empty download.allowed_networks
  end
end
