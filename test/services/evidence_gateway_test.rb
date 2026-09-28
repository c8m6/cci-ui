# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/evidence_gateway"

class EvidenceGatewayTest < ActiveSupport::TestCase
  SOURCE = "https://www.gstatic.com/ct/log_list/v3/log_list.json"
  CRL = "https://crl.example.test/issuer.crl"
  OCSP = "https://ocsp.example.test/respond"

  setup do
    @directory = Dir.mktmpdir("cci-evidence-test-")
    @environment = { "CCI_EVIDENCE_STORE_PATH" => @directory, "CCI_EVIDENCE_REFRESH_INTERVAL" => "10",
                     "CCI_EVIDENCE_CRL_URLS" => JSON.generate([CRL]),
                     "CCI_EVIDENCE_OCSP_URLS" => JSON.generate([OCSP]) }
  end

  teardown { FileUtils.remove_entry(@directory) }

  def request(app, kind, url, body: nil)
    payload = { kind: kind, url: url }
    payload[:body] = Base64.strict_encode64(body) if body
    env = Rack::MockRequest.env_for("/v1/evidence", method: "POST", input: JSON.generate(payload))
    app.call(env)
  end

  test "source and CRL bytes retain their original acquisition time and refresh after the interval" do
    calls = []
    acquired = Time.utc(2026, 9, 28, 12)
    app = EvidenceGateway::App.new(EvidenceGateway::Configuration.new(@environment), external: lambda do |kind, url, _body|
      calls << [kind, url]
      ["original evidence", acquired]
    end)

    status, headers, body = request(app, "source", SOURCE)
    assert_equal 200, status
    assert_equal "original evidence", body.join
    assert_equal acquired.iso8601, headers.fetch("x-cci-evidence-fetched-at")
    assert_equal Digest::SHA256.hexdigest(body.join), headers.fetch("x-cci-evidence-sha256")
    assert_equal 1, calls.size

    # The gateway may retain an old artifact for history after an outage, but
    # downloading it again cannot make its acquisition time current.
    status, headers, = request(app, "source", SOURCE)
    assert_equal 200, status
    assert_equal acquired.iso8601, headers.fetch("x-cci-evidence-fetched-at")
    assert_equal 2, calls.size
    app.refresh
    source_calls = calls.count { |kind, url| kind == "source" && url == SOURCE }
    assert_equal 3, source_calls
    assert_includes calls, ["crl", CRL]
    row = EvidenceGateway::Store.new(@directory).read("source", SOURCE)
    assert_equal ["original evidence", acquired], row
  end

  test "only supported source paths and explicitly allowed CRL and OCSP URLs reach the network" do
    calls = []
    app = EvidenceGateway::App.new(EvidenceGateway::Configuration.new(@environment), external: lambda do |kind, url, body|
      calls << [kind, url, body]
      ["proof", Time.now.utc]
    end)
    assert_equal 403, request(app, "source", "http://127.0.0.1/private").first
    assert_equal 403, request(app, "source", "https://raw.githubusercontent.com/attacker/other/main/file").first
    assert_equal 403, request(app, "crl", "https://other.example.test/list").first
    assert_equal 403, request(app, "ocsp", "https://other.example.test/ocsp", body: "request").first
    assert_empty calls

    assert_equal 200, request(app, "crl", CRL).first
    assert_equal 200, request(app, "ocsp", OCSP, body: "request").first
    assert_equal [["crl", CRL, nil], ["ocsp", OCSP, "request"]], calls
    assert_equal 400, request(app, "ocsp", OCSP).first
  end

  test "current source bytes are reused while CRL nextUpdate forces an earlier refresh" do
    issuer, key = issue(name: "Synthetic CRL issuer", ca: true)
    list = OpenSSL::X509::CRL.new
    list.version = 1
    list.issuer = issuer.subject
    list.last_update = Time.now - 120
    list.next_update = Time.now - 1
    list.sign(key, OpenSSL::Digest.new("SHA256"))
    calls = Hash.new(0)
    app = EvidenceGateway::App.new(EvidenceGateway::Configuration.new(@environment), external: lambda do |kind, _url, _body|
      calls[kind] += 1
      [kind == "crl" ? list.to_der : "source", Time.now.utc]
    end)
    2.times { assert_equal 200, request(app, "source", SOURCE).first }
    assert_equal 1, calls["source"]
    2.times { assert_equal 200, request(app, "crl", CRL).first }
    assert_equal 2, calls["crl"]
  end

  test "gateway mode never calls direct DNS or falls back after gateway failure" do
    config = CertificateDiagnosticsConfiguration.new({
      "CCI_EVIDENCE_GATEWAY_ENABLED" => "true", "CCI_EVIDENCE_GATEWAY_URL" => "https://gateway.example.test",
      "CCI_EVIDENCE_GATEWAY_CA_FILE" => "/run/ca.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_CERT_FILE" => "/run/client.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_KEY_FILE" => "/run/client.key"
    })
    resolver = Object.new
    def resolver.getaddresses(*) = raise "Direct DNS lookup is forbidden"

    client = Object.new
    def client.fetch(*) = raise CertificateDiagnostics::Error, "gateway_unavailable"

    original = CertificateDiagnostics::GatewayClient.method(:new)
    CertificateDiagnostics::GatewayClient.define_singleton_method(:new) { |*| client }
    error = assert_raises(CertificateDiagnostics::Error) do
      CertificateDiagnostics::Http.new(config, resolver: resolver).fetch(CRL)
    end
    assert_equal "gateway_unavailable", error.message
    assert_not CertificateDiagnosticsConfiguration.new({}).gateway?
  ensure
    CertificateDiagnostics::GatewayClient.define_singleton_method(:new, original) if original
  end

  test "one refresh interval replaces per-profile source download intervals" do
    config = CertificateDiagnosticsConfiguration.new("CCI_EVIDENCE_REFRESH_INTERVAL" => "120")
    assert_equal 120, config.trust["trust_chrome"]["update_interval"]
    assert_equal 120, config.trust["chrome_policy"]["update_interval"]
    assert_equal 21_600, config.interval("ocsp")
    assert_equal 86_400, config.interval("trust_chrome")
  end

  test "gateway configuration is opt-in and rejects incomplete or conflicting transport settings" do
    assert_not CertificateDiagnosticsConfiguration.new({}).gateway?
    incomplete = { "CCI_EVIDENCE_GATEWAY_ENABLED" => "true",
                   "CCI_EVIDENCE_GATEWAY_URL" => "https://gateway.example.test" }
    assert_raises(ArgumentError) { CertificateDiagnosticsConfiguration.new(incomplete) }
    complete = incomplete.merge("CCI_EVIDENCE_GATEWAY_CA_FILE" => "/run/ca.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_CERT_FILE" => "/run/client.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_KEY_FILE" => "/run/client.key")
    assert CertificateDiagnosticsConfiguration.new(complete).gateway?
    assert_raises(ArgumentError) do
      CertificateDiagnosticsConfiguration.new(complete.merge("CCI_EVIDENCE_GATEWAY_URL" => "http://gateway.example.test"))
    end
    assert_raises(ArgumentError) do
      CertificateDiagnosticsConfiguration.new(complete.merge("CCI_DIAGNOSTICS_HTTP_PROXY" => "http://proxy.example.test"))
    end
  end

  test "redirects cannot escape the gateway target allowlist" do
    config = EvidenceGateway::Configuration.new(@environment)
    resolver = Struct.new(:addresses) { def getaddresses(*) = addresses }.new(["8.8.8.8"])
    response = Net::HTTPFound.new("1.1", "302", "Found")
    response["location"] = "https://unlisted.example.test/private"
    http = CertificateDiagnostics::Http.new(config, resolver: resolver,
      target_policy: ->(uri) { config.targets.allowed?("source", uri) })
    calls = 0
    http.define_singleton_method(:request) do |*|
      calls += 1
      [response, ""]
    end
    error = assert_raises(CertificateDiagnostics::Error) { http.fetch(SOURCE) }
    assert_equal "blocked_destination", error.message
    assert_equal 1, calls
  end
end
