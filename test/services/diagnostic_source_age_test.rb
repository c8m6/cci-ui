# frozen_string_literal: true

require "test_helper"

class DiagnosticSourceAgeTest < ActiveSupport::TestCase
  UnavailableHttp = Struct.new(:calls) do
    def fetch(url)
      calls << url
      raise CertificateDiagnostics::Error, "network_error"
    end
  end

  class FixtureProfiles < CertificateDiagnostics::Profiles
    attr_accessor :data, :error

    def acquire(*)
      raise error if error

      data.deep_dup
    end
  end

  setup do
    travel_to Time.utc(2026, 9, 27, 12)
    @config = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true")
    @token = CertificateDiagnosticCache.acquire(CertificateDiagnostics::Runner::LEASE, seconds: 60)
    @source_time = 2.days.ago
    @cert, = issue(ca: true)
    @data = { "roots" => { Certificates::Codec.fingerprint(@cert) => { "pem" => @cert.to_pem } },
              "release" => "Synthetic profile", "source" => "Synthetic source", "scope" => "chrome_baseline",
              "acquired_at" => @source_time.iso8601 }
    service(@config).refresh
  end

  teardown { travel_back }

  def service(config)
    FixtureProfiles.new(config, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30, token: @token)
                   .tap { |provider| provider.data = @data }
  end

  test "shortened source age rejects retained profiles and results despite a failed refresh" do
    row = CertificateDiagnostics::Profiles.record("trust_chrome")
    old_payload = row.payload
    old_expiry = row.expires_at
    material = Struct.new(:certificate, :candidates).new(@cert, [])
    outcome = CertificateDiagnostics::Trust.new(material, @config).call("trust_chrome")
    assert_equal "good", outcome[:state]
    evidence = CertificateDiagnosticResult.new(outcome.slice(:state, :reason, :expires_at, :data_version, :details)
      .merge(check_id: "trust_chrome", checked_at: Time.current))
    assert_equal "good", evidence.display_state(@config)
    stricter = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true", "CCI_TRUST_CHROME_MAX_AGE" => "86400")
    # Applies immediately in the web process, before a new indexer run.
    assert_equal "stale", evidence.display_state(stricter)
    provider = service(stricter)
    provider.error = CertificateDiagnostics::Error.new("network_error")
    provider.refresh
    assert_equal "network_error", row.reload.metadata["last_error"]
    assert_equal old_payload, row.payload
    assert_equal old_expiry, row.expires_at
    assert_equal @source_time.iso8601, row.metadata["checked_at"]
    error = assert_raises(CertificateDiagnostics::Error) { CertificateDiagnostics::Profiles.load("trust_chrome", stricter) }
    assert_equal "source_expired", error.message
    assert_equal "unknown", CertificateDiagnostics::Trust.new(material, stricter).call("trust_chrome")[:state]
    assert_equal "stale", evidence.display_state(stricter)
  end

  test "current limits bound every cached profile exactly at the source age boundary" do
    TrustProfileConfiguration::DEFAULTS.each_key do |check|
      config = CertificateDiagnosticsConfiguration.new("CCI_#{check.upcase}_MAX_AGE" => "172800")
      row = CertificateDiagnosticCache.find_or_initialize_by(cache_id: "profile:#{check}")
      row.update!(payload: JSON.generate(@data.except("acquired_at")), expires_at: 5.days.from_now,
        metadata: { "target" => config.trust[check]["target"], "version" => "fixture", "checked_at" => @source_time.iso8601 })
      travel_to Time.utc(2026, 9, 27, 11, 59, 59)
      assert_equal Time.utc(2026, 9, 27, 12), CertificateDiagnostics::Profiles.load(check, config)["expires_at"]
      travel 1
      assert_raises(CertificateDiagnostics::Error, check) { CertificateDiagnostics::Profiles.load(check, config) }
    end
  end

  test "raw artifact reuse applies the current age limit and never refreshes its original timestamp" do
    url = "https://source.example.test/fixture"
    row = CertificateDiagnosticCache.create!(cache_id: "source:#{Digest::SHA256.hexdigest(url)}", payload: "original",
      expires_at: 5.days.from_now, metadata: { "fetched_at" => @source_time.iso8601 })
    http = UnavailableHttp.new([])
    download = CertificateDiagnostics::Sources::Download.new(@config, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
      http: http)
    assert_equal "original", download.get(url, max_age: 3.days)
    assert_equal @source_time, download.verified_at
    assert_empty http.calls
    assert_raises(CertificateDiagnostics::Error) { download.get(url, max_age: 2.days) }
    assert_equal [url], http.calls
    assert_equal "original", row.reload.payload
    assert_equal @source_time.iso8601, row.metadata["fetched_at"]
    assert_equal @source_time, download.verified_at
  end

  test "gateway acquisition keeps upstream age and does not reuse direct-mode source bytes" do
    url = "https://source.example.test/fixture"
    CertificateDiagnosticCache.create!(cache_id: "source:#{Digest::SHA256.hexdigest(url)}", payload: "direct",
      expires_at: 5.days.from_now, metadata: { "fetched_at" => Time.current.iso8601 })
    config = CertificateDiagnosticsConfiguration.new("CCI_EVIDENCE_GATEWAY_ENABLED" => "true",
      "CCI_EVIDENCE_GATEWAY_URL" => "https://gateway.example.test", "CCI_EVIDENCE_GATEWAY_CA_FILE" => "/run/ca.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_CERT_FILE" => "/run/client.crt",
      "CCI_EVIDENCE_GATEWAY_CLIENT_KEY_FILE" => "/run/client.key")
    assert_raises(CertificateDiagnostics::Error) { CertificateDiagnostics::Profiles.load("trust_chrome", config) }
    http = Struct.new(:fetched_at) { def fetch(*) = "gateway" }.new(@source_time)
    download = CertificateDiagnostics::Sources::Download.new(config, deadline: 1, http: http)
    assert_equal "gateway", download.get(url, max_age: 3.days)
    assert_equal @source_time, download.verified_at
    row = CertificateDiagnosticCache.find_by!(cache_id: "source:gateway:#{Digest::SHA256.hexdigest(url)}")
    assert_equal "gateway", row.payload
    assert_equal @source_time.iso8601, row.metadata.fetch("fetched_at")
    assert_raises(CertificateDiagnostics::Error) { download.get(url, max_age: 1.day) }
    assert_equal "gateway", row.reload.payload
  end

  test "reparsing artifacts and signed CT metadata preserve the oldest authoritative timestamp" do
    row = CertificateDiagnostics::Profiles.record("trust_chrome")
    row.update!(metadata: row.metadata.merge("next_due_at" => 1.second.ago.iso8601))
    service(@config).refresh
    assert_equal @source_time.iso8601, row.reload.metadata["checked_at"]
    assert_equal @source_time + 7.days, row.expires_at
    config = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true", "CCI_CHROME_POLICY_ENABLED" => "true")
    provider = service(config)
    provider.data = { "logs" => {}, "timestamp" => @source_time.iso8601, "acquired_at" => Time.current.iso8601 }
    provider.refresh
    ct = CertificateDiagnostics::Profiles.record("chrome_policy")
    assert_equal @source_time.iso8601, ct.metadata["checked_at"]
    evidence = CertificateDiagnosticResult.new(check_id: "chrome_policy", state: "good", checked_at: Time.current,
      expires_at: 5.days.from_now, details: { "source_checked_at" => Time.current.iso8601, "ct_checked_at" => @source_time.iso8601 })
    stricter = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true", "CCI_CHROME_POLICY_ENABLED" => "true",
      "CCI_CHROME_POLICY_MAX_AGE" => "86400")
    assert_equal "stale", evidence.display_state(stricter)
  end

  test "missing acquisition times cannot replace a dataset with artificially fresh evidence" do
    row = CertificateDiagnostics::Profiles.record("trust_chrome")
    expiry = row.expires_at
    row.update!(metadata: row.metadata.merge("next_due_at" => 1.second.ago.iso8601))
    provider = service(@config)
    provider.data = @data.except("acquired_at")
    provider.refresh
    assert_equal "source_verification_failed", row.reload.metadata["last_error"]
    assert_equal expiry, row.expires_at
    assert_equal @source_time.iso8601, row.metadata["checked_at"]
  end
end
