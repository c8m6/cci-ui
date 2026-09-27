# frozen_string_literal: true

require "test_helper"

class CertificateDiagnosticsRenderingTest < ActionDispatch::IntegrationTest
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
end
