require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "Consul mutations preserve snapshots and original event time after archiving and repeated indexing" do
    cert, = issue(name: "deleted-audit.test")
    first = store(cert, lookup: "audit-service")
    second_cert, = issue(name: "renewed-audit.test", serial: 2)
    second = store(second_cert, lookup: "audit-service")
    travel_to Time.current.change(usec: 0) do
      activated_at = Time.current
      ConsulStore.activate("zone_a", first.source_id, actor: "activate-user")
      travel 2.minutes
      ConsulStore.archive(second, actor: "archive-user", expected_lookup_index: ConsulStore.status_snapshot(second)[:index])
      CatalogIndexer.refresh_consul
      assert second.reload.archived
      assert first.reload.archived
      activated = AuditEvent.find_by!(action: "activate")
      assert_equal activated_at, activated.occurred_at
      assert_equal second.source_id, activated.details["previous_version"]
      deleted = AuditEvent.find_by!(action: "archive")
      assert_equal "archive-user", deleted.actor
      assert_equal "renewed-audit.test", deleted.details["certificates"].first["common_name"]
      assert_equal second.fingerprint, deleted.details["certificates"].first["fingerprint"]
      assert_no_difference "AuditEvent.count" do
        CatalogIndexer.refresh_consul
        ConsulStore.archive(second, actor: "retry", expected_lookup_index: ConsulStore.status_snapshot(second)[:index])
        CatalogIndexer.refresh_consul
      end
    end
    assert_equal 4, AuditEvent.count
    assert_equal first.source_id, AuditEvent.where(action: "import").order(:id).last.details["previous_version"]
  end

  test "mixed area export writes separate audit records in one transaction" do
    records = %w[zone_a zone_b].map { |area| store(issue(name: "#{area}.test").first, area: area) }
    identity = Identity.new(name: "mixed-export-user", roles: %w[zone_a_writer zone_b_writer])
    assert_difference "AuditEvent.count", 2 do
      content, filename, = CertificateExport.call(records, identity: identity, format: "pem",
        include_key: false, include_chain: false, password: "")
      assert_equal "zertifikate.zip", filename
      assert content.start_with?("PK")
    end
    events = AuditEvent.where(action: "export_public").order(:area)
    assert_equal %w[zone_a zone_b], events.map(&:area)
    assert_equal 1, events.map(&:occurred_at).uniq.size
    events.zip(records).each { |event, record| assert_equal [record.fingerprint], event.details["certificates"].map { |cert| cert["fingerprint"] } }
  end
end
