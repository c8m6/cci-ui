# frozen_string_literal: true

require "test_helper"

class CertificateDiagnosticsRenderingTest < ActionDispatch::IntegrationTest
  setup do
    @previous_ocsp = ENV.fetch("CCI_OCSP_ENABLED", nil)
    @previous_crl = ENV.fetch("CCI_CRL_ENABLED", nil)
    ENV["CCI_OCSP_ENABLED"] = "true"
    ENV["CCI_CRL_ENABLED"] = "true"
  end

  teardown do
    ENV["CCI_OCSP_ENABLED"] = @previous_ocsp
    ENV["CCI_CRL_ENABLED"] = @previous_crl
  end

  test "detail requests only render persisted evidence in both languages and preserve visibility" do
    record = store(issue.first)
    hidden = store(issue.first, area: "zone_b", certid: "hidden")
    post local_login_path, params: { identity: "zone_a_reader" }
    %w[en de].each do |locale|
      get certificate_path(record, locale: locale)
      assert_response :success
      assert_select "#diagnostics-heading"
      assert_select ".certificate-diagnostics .badge.neutral", count: 2
      assert_not_includes response.body, "translation missing"
    end
    assert_empty CertificateDiagnosticResult.all
    get certificate_path(hidden)
    assert_response :not_found
  end

  test "only enabled checks appear even when disabled checks have stored evidence" do
    record = store(issue.first)
    %w[ocsp crl].each do |check|
      CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint, check_id: check,
        state: "good", reason: "good", checked_at: Time.current, expires_at: 1.hour.from_now, next_due_at: 1.hour.from_now)
    end
    post local_login_path, params: { identity: "zone_a_reader" }
    [[], ["ocsp"], ["crl"], %w[ocsp crl]].each do |enabled|
      ENV["CCI_OCSP_ENABLED"] = enabled.include?("ocsp").to_s
      ENV["CCI_CRL_ENABLED"] = enabled.include?("crl").to_s
      %w[en de].each do |locale|
        get certificate_path(record, locale: locale)
        assert_response :success
        assert_select "#diagnostics-heading", count: enabled.empty? ? 0 : 1
        assert_select ".certificate-diagnostics .diagnostic-item > dt", text: "OCSP", count: enabled.include?("ocsp") ? 1 : 0
        assert_select ".certificate-diagnostics .diagnostic-item > dt", text: "CRL", count: enabled.include?("crl") ? 1 : 0
        assert_select ".certificate-diagnostics .badge.success", count: enabled.size
        assert_select ".certificate-diagnostics .badge.neutral", count: 0
      end
    end
    assert_equal 2, CertificateDiagnosticResult.count
  end
  test "each public profile renders independently in both languages without acquiring sources" do
    record = store(issue.first)
    ENV["CCI_OCSP_ENABLED"] = ENV["CCI_CRL_ENABLED"] = "false"
    names = TrustProfileConfiguration::DEFAULTS.keys.excluding("chrome_policy").to_h { |check| ["CCI_#{check.upcase}_ENABLED", ENV.fetch("CCI_#{check.upcase}_ENABLED", nil)] }
    names.each_key { |name| ENV[name] = "false" }
    post local_login_path, params: { identity: "zone_a_reader" }
    names.each_key do |name|
      ENV[name] = "true"
      %w[en de].each do |locale|
        get certificate_path(record, locale: locale)
        assert_response :success
        assert_select ".certificate-diagnostics .diagnostic-item > dt", count: 1
        assert_select ".certificate-diagnostics .badge.neutral", count: 1
        assert_not_includes response.body, "translation missing"
      end
      ENV[name] = "false"
    end
    assert_empty CertificateDiagnosticResult.all
    assert_empty CertificateDiagnosticCache.all
  ensure
    names&.each { |name, value| ENV[name] = value }
  end
  test "enabled policy cannot leave a green Chrome badge with unresolved or stale evidence" do
    previous = %w[CCI_TRUST_CHROME_ENABLED CCI_CHROME_POLICY_ENABLED].to_h { |name| [name, ENV.fetch(name, nil)] }
    previous.each_key { |name| ENV[name] = "true" }
    record = store(issue.first)
    CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint, check_id: "trust_chrome",
      state: "good", reason: "tls_path_trusted", checked_at: Time.current, expires_at: 1.hour.from_now, next_due_at: Time.current,
      details: { "scope" => "chrome_baseline" })
    post local_login_path, params: { identity: "zone_a_reader" }
    %w[en de].each do |locale|
      get certificate_path(record, locale: locale)
      assert_response :success
      assert_select ".certificate-diagnostics .badge.success", count: 0
      assert_select ".certificate-diagnostics-browsers .diagnostic-item > dt", count: 2
      assert_not_includes response.body, "translation missing"
    end
    assert_select '.certificate-diagnostics-browsers [data-check="trust_chrome"] + [data-check="chrome_policy"]', count: 1
    policy = CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint, check_id: "chrome_policy",
      state: "unknown", reason: "chrome_policy_incomplete", checked_at: Time.current, next_due_at: Time.current)
    get certificate_path(record)
    assert_select ".certificate-diagnostics .badge.success", count: 0
    policy.update!(state: "good", reason: "chrome_policy_satisfied", expires_at: 1.hour.from_now)
    get certificate_path(record)
    assert_select ".certificate-diagnostics .badge.success", count: 2
    policy.update!(expires_at: 1.second.ago)
    get certificate_path(record)
    assert_select ".certificate-diagnostics .badge.success", count: 0
    ENV["CCI_CHROME_POLICY_ENABLED"] = "false"
    get certificate_path(record)
    assert_select ".certificate-diagnostics .badge.success", count: 1
    assert_select ".certificate-diagnostics .diagnostic-item > dt", text: "Additional Chrome policy", count: 0
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end
end
