require "test_helper"

class AuditEventsTest < ActionDispatch::IntegrationTest
  test "audit roles are independent and restricted to their area" do
    zone_a = store(issue(name: "zone_a-audit.test").first)
    store(issue(name: "zone_b-audit.test").first, area: "zone_b")
    get audit_events_path
    assert_redirected_to login_path
    %w[zone_a_reader zone_a_writer all:keys].each do |role|
      post local_login_path, params: { identity: role }
      get audit_events_path
      assert_response :forbidden
      get root_path
      assert_select "nav a[href=?]", audit_events_path, count: 0
    end
    post local_login_path, params: { identity: "zone_a_auditor" }
    assert_redirected_to audit_events_path
    get audit_events_path
    assert_response :success
    assert_includes response.body, "zone_a-audit.test"
    assert_not_includes response.body, "zone_b-audit.test"
    assert_select "nav a[href=?]", audit_events_path, count: 1
    get audit_events_path, params: { area: "zone_b", q: "zone_b-audit.test" }
    assert_response :success
    assert_not_includes response.body, "zone_b-audit.test</strong>"
    assert_select ".audit-certificate", count: 0
    get certificate_path(zone_a)
    assert_response :not_found
    get new_import_path
    assert_response :forbidden
    assert_no_difference "AuditEvent.count" do
      post export_certificates_path, params: { ids: [zone_a.id], format_name: "pem" }
      assert_response :not_found
    end
    post local_login_path, params: { identity: "all:auditor" }
    get audit_events_path
    assert_includes response.body, "zone_b-audit.test"
  end

  test "successful exports record actual selected certificates chains options time and user" do
    root, root_key = issue(name: "Audit Root", ca: true)
    cert, key = issue(name: "audit-leaf.test", issuer: root, issuer_key: root_key)
    record = store(cert, key: key, chain: [root])
    post local_login_path, params: { identity: "zone_a_keys" }
    %w[pem der p12 jks].each do |format|
      private_export = format != "der"
      assert_difference "AuditEvent.count", 1 do
        post export_certificates_path, params: { ids: [record.id], format_name: format,
          include_chain: private_export ? "1" : "0", include_key: private_export ? "1" : "0", password: "audit-password-long" }
        assert_response :success
      end
      event = AuditEvent.order(:id).last
      assert_equal "Zone A · Writer + Key Exporter", event.actor
      assert_equal private_export ? "export_private" : "export_public", event.action
      assert_in_delta Time.current.to_f, event.occurred_at.to_f, 5
      assert_equal format, event.details["format"]
      assert_equal [record.source_id], event.references
      assert_equal private_export ? [record.fingerprint, Certificates::Codec.fingerprint(root)] : [record.fingerprint],
        event.details["certificates"].map { |item| item["fingerprint"] }
      assert_not_includes event.details.to_json, "PRIVATE KEY"
      assert_not_includes event.details.to_json, "audit-password-long"
    end
    post local_login_path, params: { identity: "zone_a_reader" }
    assert_no_difference "AuditEvent.count" do
      post export_certificates_path, params: { ids: [record.id], format_name: "pem" }
    end
  end

  test "audit filters paginate and preserve historical entries" do
    32.times do |index|
      AuditEvent.create!(area: "zone_a", action: "export_public", actor: "user-#{index}",
        occurred_at: Time.zone.parse("2026-09-10 23:30:00") + index.seconds, references: ["old-reference"])
    end
    AuditEvent.create!(area: "zone_a", action: "delete", actor: "excluded", occurred_at: Time.zone.parse("2026-09-11 00:01:00"))
    post local_login_path, params: { identity: "zone_a_auditor" }
    filters = { event_action: "export_public", from: "2026-09-10", to: "2026-09-10", q: "user-" }
    get audit_events_path, params: filters
    assert_response :success
    assert_select "tbody tr", count: 30
    assert_includes response.body, "nur Referenzen vorhanden"
    assert_not_includes response.body, "excluded"
    get audit_events_path, params: filters.merge(page: 2)
    assert_select "tbody tr", count: 2
    get audit_events_path, params: { from: "invalid" }
    assert_response :unprocessable_content
  end
end
