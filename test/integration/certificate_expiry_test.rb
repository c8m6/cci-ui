# frozen_string_literal: true

require "test_helper"

class CertificateExpiryTest < ActionDispatch::IntegrationTest
  setup do
    @previous = ENV.fetch("CCI_CERTIFICATE_EXPIRY_WARNING_DAYS", nil)
    ENV.delete("CCI_CERTIFICATE_EXPIRY_WARNING_DAYS")
  end

  teardown do
    ENV["CCI_CERTIFICATE_EXPIRY_WARNING_DAYS"] = @previous
  end

  test "warning period defaults and invalid configuration" do
    assert_equal 10, CertificateExpiryConfiguration.warning_days({})
    assert_equal 10, CertificateExpiryConfiguration.warning_days("CCI_CERTIFICATE_EXPIRY_WARNING_DAYS" => " ")
    %w[0 -1 1.5 invalid].each do |value|
      assert_raises(ArgumentError) do
        CertificateExpiryConfiguration.warning_days("CCI_CERTIFICATE_EXPIRY_WARNING_DAYS" => value)
      end
    end
  end

  test "badges search statistics and translations share the configured warning period" do
    travel_to Time.zone.local(2026, 9, 28, 12) do
      post local_login_path, params: { identity: "zone_a_reader" }
      record = store(issue.first)
      record.update!(not_before: 1.day.ago, not_after: 15.days.from_now)
      assert_equal "valid", record.status_key
      assert_empty CertificateSearch.call(Certificate.all, status: "soon")
      get certificates_path
      assert_select ".stat-card small", text: "Innerhalb der nächsten 10 Tage"

      ENV["CCI_CERTIFICATE_EXPIRY_WARNING_DAYS"] = "20"
      assert_equal "expiring", record.status_key
      assert_equal [record.id], CertificateSearch.call(Certificate.all, status: "soon").pluck(:id)
      get certificates_path
      assert_select ".stat-card", text: /Läuft bald ab\s*1\s*Innerhalb der nächsten 20 Tage/
      get certificates_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
      assert_select ".stat-card small", text: "Within the next 20 days"

      record.update!(not_after: 20.days.from_now)
      assert_equal "valid", record.status_key
      assert_empty CertificateSearch.call(Certificate.all, status: "soon")
      record.update!(not_after: Time.current)
      assert_equal "expired", record.status_key
      record.update!(not_before: 1.day.from_now, not_after: 2.days.from_now)
      assert_equal "future", record.status_key
      assert_empty CertificateSearch.call(Certificate.all, status: "soon")
    end
  end
end
