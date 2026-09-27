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
        assert_select ".certificate-diagnostics > dt", text: "OCSP", count: enabled.include?("ocsp") ? 1 : 0
        assert_select ".certificate-diagnostics > dt", text: "CRL", count: enabled.include?("crl") ? 1 : 0
        assert_select ".certificate-diagnostics .badge.success", count: enabled.size
        assert_select ".certificate-diagnostics .badge.neutral", count: 0
      end
    end
    assert_equal 2, CertificateDiagnosticResult.count
  end
end
