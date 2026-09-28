# frozen_string_literal: true

require "test_helper"

class DiagnosticSchedulingTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 27, 12)
    @config = CertificateDiagnosticsConfiguration.new("CCI_OCSP_ENABLED" => "true", "CCI_DIAGNOSTICS_BATCH_SIZE" => "1")
  end

  teardown { travel_back }

  def result(record)
    CertificateDiagnosticResult.find_by!(area: record.area, fingerprint: record.fingerprint, check_id: "ocsp")
  end

  test "continuous unrelated arrivals preserve waiting time and progress for archived and inactive versions" do
    first = store(issue(name: "Active root", ca: true).first, certid: "first")
    archived = store(issue(name: "Archived root", ca: true).first, certid: "archived")
    inactive = store(issue(name: "Inactive root", ca: true).first, certid: "inactive")
    first_check = nil
    5.times do |index|
      # Source refreshes in store restore Consul control state, so maintain the
      # three explicit scheduling priorities for this isolated fixture.
      archived.update!(active: false, archived: true, rollout_status: "delete")
      inactive.update!(active: false)
      CertificateDiagnostics::Runner.run(@config)
      first_check ||= result(first).checked_at
      assert_equal first_check, result(first).checked_at
      travel 60
      store(issue(name: "Unrelated root #{index}", ca: true).first, certid: "new-#{index}")
    end
    assert result(archived).checked_at
    assert result(inactive).checked_at
    assert_equal "valid", archived.status_key
  end

  test "direct transitive alternate and removed issuers invalidate only dependent material" do
    root, root_key = issue(name: "Root", ca: true)
    issuer, issuer_key = issue(name: "Issuer", ca: true, issuer: root, issuer_key: root_key)
    leaf, = issue(issuer: issuer, issuer_key: issuer_key)
    record = store(leaf)
    CertificateDiagnostics::Runner.run(@config)
    assert_equal "missing_issuer", result(record).reason
    initial = result(record).input_version
    travel 1
    store(issuer, certid: "issuer")
    CertificateDiagnostics::Runner.run(@config)
    assert_equal "missing_url", result(record).reason
    assert_not_equal initial, result(record).input_version
    material = CertificateDiagnostics::Material.new(record)
    before_root = material.identity
    root_record = store(root, certid: "root")
    assert_not material.current?
    after_root = CertificateDiagnostics::Inventory.new(record.area).version(record.fingerprint)
    assert_not_equal before_root, after_root
    other, other_key = issue(name: "Alternate root", ca: true)
    cross = OpenSSL::X509::Certificate.new(issuer.to_der)
    cross.issuer = other.subject
    cross.sign(other_key, "SHA256")
    alternate = store(cross, certid: "cross", chain: [other])
    with_cross = CertificateDiagnostics::Inventory.new(record.area).version(record.fingerprint)
    assert_not_equal after_root, with_cross
    alternate.update!(deleted_at: Time.current)
    assert_equal after_root, CertificateDiagnostics::Inventory.new(record.area).version(record.fingerprint)
    root_record.update!(deleted_at: Time.current)
    assert_equal before_root, CertificateDiagnostics::Inventory.new(record.area).version(record.fingerprint)
    material = CertificateDiagnostics::Material.new(record)
    store(issue(name: "Unrelated").first, certid: "unrelated")
    store(root, area: "zone_b", certid: "foreign")
    assert material.current?
  end

  test "invalidation and reenabling never reset the age of overdue jobs" do
    record = store(issue(ca: true).first)
    waiting_since = 2.hours.ago
    expired_since = 1.hour.ago
    job = CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint,
      check_id: "ocsp", input_version: "old", next_due_at: waiting_since, expires_at: expired_since, suspended: true)
    runner = CertificateDiagnostics::Runner.new(@config)
    runner.instance_variable_set(:@token, CertificateDiagnosticCache.acquire(CertificateDiagnostics::Runner::LEASE, seconds: 60))
    runner.send(:schedule)
    assert_equal waiting_since, job.reload.next_due_at
    assert_equal expired_since, job.expires_at
    assert_not job.suspended
    assert_not_equal "old", job.input_version
  end
end
