# frozen_string_literal: true

require "test_helper"

class TrustProfileCacheTest < ActiveSupport::TestCase
  class FixtureProfiles < CertificateDiagnostics::Profiles
    attr_accessor :data, :error

    def acquire(*)
      raise error if error

      data
    end
  end

  setup do
    @config = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true")
    @token = CertificateDiagnosticCache.acquire(CertificateDiagnostics::Runner::LEASE, seconds: 60)
    @service = FixtureProfiles.new(@config, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30, token: @token)
    cert, = issue(ca: true)
    @service.data = { "roots" => { Certificates::Codec.fingerprint(cert) => { "pem" => cert.to_pem } } }
  end

  test "atomic profile refresh preserves prior payload age and version on failure" do
    @service.refresh
    row = CertificateDiagnostics::Profiles.record("trust_chrome")
    original = row.payload
    expiry = row.expires_at
    version = row.metadata["version"]
    row.update!(metadata: row.metadata.merge("next_due_at" => 1.second.ago.iso8601))
    @service.error = CertificateDiagnostics::Error.new("network_error")
    @service.refresh
    assert_equal original, row.reload.payload
    assert_equal expiry, row.expires_at
    assert_equal version, row.metadata["version"]
    assert_equal "network_error", row.metadata["last_error"]
    row.update!(expires_at: 1.second.ago)
    assert_raises(CertificateDiagnostics::Error) { CertificateDiagnostics::Profiles.load("trust_chrome", @config) }
  end

  test "changed profile invalidates old evidence and fenced workers cannot publish datasets" do
    @service.refresh
    old = CertificateDiagnostics::Profiles.version("trust_chrome", @config)
    row = CertificateDiagnostics::Profiles.record("trust_chrome")
    row.update!(metadata: row.metadata.merge("next_due_at" => 1.second.ago.iso8601))
    @service.data["release"] = "next fixture release"
    @service.refresh
    assert_not_equal old, CertificateDiagnostics::Profiles.version("trust_chrome", @config)
    evidence = CertificateDiagnosticResult.new(check_id: "trust_chrome", state: "good", checked_at: Time.current,
      expires_at: 1.hour.from_now, data_version: old)
    assert_equal "stale", evidence.display_state(@config)
    CertificateDiagnosticCache.release(CertificateDiagnostics::Runner::LEASE, @token)
    row.update!(metadata: row.metadata.merge("next_due_at" => 1.second.ago.iso8601))
    previous = row.reload.payload
    @service.data["release"] = "fenced"
    @service.refresh
    assert_equal previous, row.reload.payload
  end

  test "all disabled skips source acquisition and changed target never uses old roots" do
    @service.error = "unexpected network"
    disabled = FixtureProfiles.new(CertificateDiagnosticsConfiguration.new({}), deadline: 0, token: @token)
    disabled.refresh
    assert_nil CertificateDiagnostics::Profiles.record("trust_chrome")
    @service.error = nil
    @service.refresh
    changed = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_TARGET" => "155.0.1.2")
    assert_equal "unavailable", CertificateDiagnostics::Profiles.version("trust_chrome", changed)
    assert_raises(CertificateDiagnostics::Error) { CertificateDiagnostics::Profiles.load("trust_chrome", changed) }
  end
end
