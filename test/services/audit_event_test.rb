require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "Consul mutations preserve snapshots and original event time after archiving and repeated indexing" do
    cert, = issue(name: "deleted-audit.test")
    first = store(cert, certid: "audit-service")
    second_cert, = issue(name: "renewed-audit.test", serial: 2)
    second = store(second_cert, certid: "audit-service")
    travel_to Time.current.change(usec: 0) do
      activated_at = Time.current
      ConsulStore.activate("zone_a", first.source_id, actor: "activate-user")
      travel 2.minutes
      ConsulStore.archive(second, actor: "archive-user", expected_certid_index: ConsulStore.status_snapshot(second)[:index])
      CatalogIndexer.refresh_consul
      assert second.reload.archived
      assert first.reload.archived
      activated = AuditEvent.find_by!(action: "activate")
      assert_equal activated_at, activated.occurred_at
      assert_equal second.certificate_version, activated.details["previous_version"]
      deleted = AuditEvent.find_by!(action: "archive")
      assert_equal "archive-user", deleted.actor
      assert_equal "renewed-audit.test", deleted.details["certificates"].first["common_name"]
      assert_equal second.fingerprint, deleted.details["certificates"].first["fingerprint"]
      assert_no_difference "AuditEvent.count" do
        CatalogIndexer.refresh_consul
        ConsulStore.archive(second, actor: "retry", expected_certid_index: ConsulStore.status_snapshot(second)[:index])
        CatalogIndexer.refresh_consul
      end
    end
    assert_equal 4, AuditEvent.count
    assert_equal first.certificate_version, AuditEvent.where(action: "import").order(:id).last.details["previous_version"]
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
  test "an audit intent exists before Consul and records rejected or uncertain writes" do
    cert, = issue
    connection = ConsulStore.client
    original_client = ConsulStore.method(:client)
    ConsulStore.define_singleton_method(:client) { connection }
    [ConsulConnection::Conflict, ConsulConnection::Error].zip(%w[rejected unknown]).each do |error_class, outcome|
      connection.define_singleton_method(:transaction) do |_operations|
        event = AuditEvent.order(:id).last
        raise "Missing durable audit intent" unless event.details.fetch("outcome") == "pending" && event.actor == "alice"
        raise error_class, "simulated write failure"
      end
      assert_raises(outcome == "rejected" ? Certificates::Error : ConsulConnection::Error) do
        ConsulStore.save(area: "zone_a", certid: "audit-failure", cert: cert, key: nil, tags: [], actor: "alice", client: "cci-ui")
      end
      event = AuditEvent.order(:id).last
      assert_equal outcome, event.details.fetch("outcome")
      assert_equal 1, event.details.fetch("after").fetch("active_version")
      assert_equal Certificates::Codec.fingerprint(cert), event.details.fetch("certificates").first.fetch("fingerprint")
      assert_not_includes event.details.to_json, "BEGIN CERTIFICATE"
      assert_nil connection.get("#{ConsulStore.prefix('zone_a')}/certids/audit-failure")
    end
  ensure
    ConsulStore.define_singleton_method(:client, original_client) if original_client
  end

  test "failure to persist audit intent prevents Consul write" do
    cert, = issue
    original_create = AuditEvent.method(:create!)
    AuditEvent.define_singleton_method(:create!) { |**_attrs| raise ActiveRecord::ConnectionNotEstablished }
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      ConsulStore.save(area: "zone_a", certid: "audit-unavailable", cert: cert, key: nil, tags: [], actor: "alice", client: "cci-ui")
    end
    assert_empty ConsulStore.client.all("#{ConsulStore.prefix('zone_a')}/")
  ensure
    AuditEvent.define_singleton_method(:create!, original_create) if original_create
  end

  test "different users retain independent immutable action snapshots" do
    first = store(issue.first)
    ConsulStore.set_status(first.area, first.source_id, status: "norollout", actor: "alice",
      expected_certid_index: ConsulStore.status_snapshot(first).fetch(:index))
    alice = AuditEvent.order(:id).last
    ConsulStore.set_status(first.area, first.source_id, status: "delete", actor: "bob",
      expected_certid_index: ConsulStore.status_snapshot(first).fetch(:index))
    bob = AuditEvent.order(:id).last
    assert_equal "alice", alice.reload.actor
    assert_equal "norollout", alice.details.fetch("after").fetch("status")
    assert_equal "bob", bob.actor
    assert_equal "norollout", bob.details.fetch("before").fetch("status")
    assert_equal "delete", bob.details.fetch("after").fetch("status")
    assert_equal "succeeded", bob.details.fetch("outcome")
  end

end
