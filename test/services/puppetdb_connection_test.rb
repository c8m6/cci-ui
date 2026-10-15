# frozen_string_literal: true

require "test_helper"
require "socket"

class PuppetdbConnectionTest < ActiveSupport::TestCase
  def connection(values) = PuppetdbConnection.new(configuration: puppetdb_settings(values))

  def with_server(body:, status: 200, headers: {}, tls: nil)
    socket = TCPServer.new("127.0.0.1", 0)
    listener = tls ? OpenSSL::SSL::SSLServer.new(socket, tls) : socket
    requests = Queue.new
    thread = Thread.new do
      client = listener.accept
      first_line = client.gets
      incoming_headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        incoming_headers[name.downcase] = value.strip
      end
      incoming_body = client.read(incoming_headers.fetch("content-length", "0").to_i)
      requests << [first_line, incoming_headers, incoming_body]
      outgoing_headers = { "Content-Type" => "application/json", "Content-Length" => body.bytesize,
                           "Connection" => "close" }.merge(headers)
      header_lines = outgoing_headers.map { |key, value| "#{key}: #{value}\r\n" }.join
      client.write("HTTP/1.1 #{status} Test\r\n#{header_lines}\r\n#{body}")
    rescue OpenSSL::SSL::SSLError, Errno::EPIPE, Errno::ECONNRESET
      # Expected when the client rejects the test CA or aborts a response.
    ensure
      client&.close
    end
    thread.report_on_exception = false
    yield "#{tls ? "https" : "http"}://127.0.0.1:#{socket.addr[1]}", requests
  ensure
    socket&.close
    if thread
      thread.join(2) || thread.kill
      thread.value
    end
  end

  test "PQL is posted as JSON to the v4 endpoint with optional base path and total verification" do
    query = 'inventory[certname,facts]{ certname in fact_contents[certname]{ name = "certificates" } }'
    rows = [{ "certname" => "web.example.test", "facts" => { "certificates" => [] } }]
    with_server(body: JSON.generate(rows), headers: { "X-Records" => "1" }) do |url, requests|
      connection = connection({ "url" => "#{url}/proxy/" })
      LogContext.with(request_id: "puppetdb-request") { assert_equal rows, connection.inventory(query) }
      line, headers, body = requests.pop
      assert_equal "POST /proxy/pdb/query/v4?include_total=true HTTP/1.1\r\n", line
      assert_equal "application/json", headers["content-type"]
      assert_equal({ "query" => query }, JSON.parse(body))
      assert_nil headers["x-authentication"]
      assert_equal "puppetdb-request", headers["x-request-id"]
    end
  end

  test "limited probes can omit total verification" do
    rows = [{ "certname" => "web.example.test" }]
    with_server(body: JSON.generate(rows), headers: { "X-Records" => "27" }) do |url, requests|
      connection = connection({ "url" => url })
      assert_equal rows, connection.inventory("nodes[certname] { limit 1 }", verify_total: false)
      assert_equal "POST /pdb/query/v4 HTTP/1.1\r\n", requests.pop.first
    end
  end

  test "HTTP errors invalid JSON truncated results and oversized bodies are rejected without leaking content" do
    [
      { body: "private response detail", status: 403 },
      { body: "private response detail", status: 302 },
      { body: "not-json" },
      { body: "{}" },
      { body: "[]", headers: { "X-Records" => "2" } },
      { body: "[]", headers: { "X-Records" => "invalid" } },
      { body: "#{" " * 20}[]" }
    ].each do |response|
      with_server(**response) do |url, _|
        connection = connection({ "url" => url,
                                                           "request.max_response_bytes" => "10" })
        error = assert_raises(PuppetdbConnection::Error) { connection.inventory("inventory {}") }
        assert_not_includes error.message, "private response detail"
      end
    end
  end

  test "connection settings reject invalid URLs credentials over HTTP and invalid limits" do
    ["", "file:///tmp/secret", "https://user:password@example.test", "https://example.test?token=secret",
      "https://example.test#fragment"].each do |url|
      error = assert_raises(PuppetdbConnection::Error) { connection({ "url" => url }) }
      assert_not_includes error.message, "password"
      assert_not_includes error.message, "secret"
    end
    [{ "authentication.token" => "secret" }, { "tls.cert_file" => "/tmp/cert" },
      { "request.timeout" => "0" }, { "request.max_response_bytes" => "bad" }].each do |settings|
      assert_raises(PuppetdbConnection::Error) { connection({ "url" => "http://example.test" }.merge(settings)) }
    end
  end

  test "HTTPS verifies the CA and supports client certificates and authentication tokens" do
    ca, ca_key = issue(name: "Test CA", ca: true)
    server, server_key = issue(name: "localhost", issuer: ca, issuer_key: ca_key, serial: 2)
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = server
    factory.issuer_certificate = ca
    server.extensions = server.extensions.reject { |extension| extension.oid == "subjectAltName" } +
                        [factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1")]
    server.sign(ca_key, OpenSSL::Digest.new("SHA256"))
    client_cert, client_key = issue(name: "inventory-reader", issuer: ca, issuer_key: ca_key, serial: 3)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = server
    context.key = server_key
    context.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(ca) }
    context.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
    Dir.mktmpdir do |dir|
      { "ca.pem" => ca.to_pem, "client.pem" => client_cert.to_pem,
        "client.key" => client_key.private_to_pem }.each do |name, value|
        File.write(File.join(dir, name), value)
      end
      settings = { "tls.ca_file" => File.join(dir, "ca.pem"), "tls.cert_file" => File.join(dir, "client.pem"),
                   "tls.key_file" => File.join(dir, "client.key"), "authentication.token" => "test-token" }
      with_server(body: "[]", tls: context) do |url, requests|
        assert_equal [],
          connection(settings.merge("url" => url)).inventory("inventory {}")
        assert_equal "test-token", requests.pop[1]["x-authentication"]
      end
      with_server(body: "[]", tls: context) do |url, _|
        assert_raises(PuppetdbConnection::Error) do
          connection(settings.except("tls.ca_file").merge("url" => url)).inventory("inventory {}")
        end
      end
    end
  end
end
