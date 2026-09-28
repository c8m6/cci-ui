# frozen_string_literal: true

require "test_helper"
require "socket"

class EvidenceGatewayClientTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("cci-gateway-client-")
    @ca, @ca_key = issue(name: "Synthetic Gateway CA", ca: true)
    @server_cert, @server_key = issue(name: "localhost", issuer: @ca, issuer_key: @ca_key)
    @client_cert, @client_key = issue(name: "Synthetic CCI client", issuer: @ca, issuer_key: @ca_key)
    File.binwrite(File.join(@directory, "ca.crt"), @ca.to_pem)
    File.binwrite(File.join(@directory, "client.crt"), @client_cert.to_pem)
    File.binwrite(File.join(@directory, "client.key"), @client_key.private_to_pem)
  end

  teardown { FileUtils.remove_entry(@directory) }

  def with_gateway(digest: Digest::SHA256.hexdigest("proof"))
    tcp = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = @server_cert
    context.key = @server_key
    context.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(@ca) }
    context.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
    server = OpenSSL::SSL::SSLServer.new(tcp, context)
    captured = Queue.new
    worker = Thread.new do
      socket = server.accept
      captured << socket.peer_cert.subject.to_s
      headers = {}
      socket.gets
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      captured << JSON.parse(socket.read(headers.fetch("content-length").to_i))
      response = [
        "HTTP/1.1 200 OK",
        "Content-Length: 5",
        "X-CCI-Evidence-SHA256: #{digest}",
        "X-CCI-Evidence-Fetched-At: #{Time.now.utc.iso8601}",
        "Connection: close",
        "",
        "proof"
      ].join("\r\n")
      socket.write(response)
      socket.close
    end
    config = CertificateDiagnosticsConfiguration.new("CCI_EVIDENCE_GATEWAY_ENABLED" => "true",
      "CCI_EVIDENCE_GATEWAY_URL" => "https://localhost:#{tcp.addr[1]}",
      "CCI_EVIDENCE_GATEWAY_CA_FILE" => File.join(@directory, "ca.crt"),
      "CCI_EVIDENCE_GATEWAY_CLIENT_CERT_FILE" => File.join(@directory, "client.crt"),
      "CCI_EVIDENCE_GATEWAY_CLIENT_KEY_FILE" => File.join(@directory, "client.key"))
    yield config, captured
  ensure
    tcp&.close
    worker&.join(2)
    worker&.kill if worker&.alive?
  end

  test "HTTPS client presents its certificate and verifies original bytes and digest" do
    with_gateway do |config, captured|
      result = CertificateDiagnostics::GatewayClient.new(config).fetch("ocsp", "https://ocsp.example.test/", body: "request")
      assert_equal "proof", result.fetch(:bytes)
      assert_equal @client_cert.subject.to_s, captured.pop
      assert_equal({ "kind" => "ocsp", "url" => "https://ocsp.example.test/",
                     "body" => Base64.strict_encode64("request") }, captured.pop)
    end
  end

  test "a corrupted gateway response cannot become evidence" do
    with_gateway(digest: "0" * 64) do |config, _|
      error = assert_raises(CertificateDiagnostics::Error) do
        CertificateDiagnostics::GatewayClient.new(config).fetch("source", "https://www.gstatic.com/ct/log_list/v3/log_list.json")
      end
      assert_equal "gateway_unavailable", error.message
    end
  end
end
