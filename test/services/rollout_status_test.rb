# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/add_certificate"

class RolloutStatusTest < ActiveSupport::TestCase
  def set_status(record, status, index: ConsulStore.status_snapshot(record)&.fetch(:index) || 0)
    options = { status: status, actor: "status-writer", expected_certid_index: index }
    ConsulStore.set_status(record.area, record.source_id, **options)
    CatalogIndexer.refresh_consul
  end

  test "status survives renewal activation reindex and is audited without changing material" do
    original = store(issue.first)
    public_data = ConsulStore.get(original.area, original.source_id)
    assert_equal "active", original.rollout_status
    set_status(original, "norollout")
    assert_equal "norollout", original.reload.rollout_status
    assert_equal public_data, ConsulStore.get(original.area, original.source_id)
    newer = store(issue(serial: 2).first)
    assert_equal "norollout", newer.rollout_status
    set_status(newer, "delete")
    ConsulStore.activate(original.area, original.source_id, actor: "test")
    CatalogIndexer.refresh_consul
    assert original.reload.active
    assert_equal "delete", original.rollout_status
    assert_equal "delete", newer.reload.rollout_status
    event = AuditEvent.where(action: "status_change").order(:id).last
    assert_equal "status-writer", event.actor
    assert_equal "norollout", event.details["previous_status"]
    assert_equal "delete", event.details["status"]
    assert_equal newer.fingerprint, event.details["certificates"].first["fingerprint"]
    assert_not_includes event.details.to_json, "PRIVATE KEY"
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace)
    assert_equal "delete",
      reader.read_certificate(area: original.area, certid: original.certid, field: "metadata")["status"]
    assert_equal public_data["pem"], reader.read_certificate(area: original.area, certid: original.certid)
    set_status(original, "active")
    assert_equal "active", original.reload.rollout_status
  end

  test "old certids default to active and external renewals preserve status" do
    record = store(issue.first)
    snapshot = ConsulStore.status_snapshot(record)
    path = "#{ConsulStore.prefix(record.area)}/certids/#{record.certid}"
    entry = JSON.parse(snapshot[:value]).except("status")
    ConsulStore.client.transaction([ConsulConnection.set(path, entry, index: snapshot[:index])])
    CatalogIndexer.refresh_consul
    assert_equal "active", record.reload.rollout_status
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace)
    assert_equal "active",
      reader.read_certificate(area: record.area, certid: record.certid, field: "metadata")["status"]
    set_status(record, "delete")
    newer = CertificateExample.add(area: record.area, certid: record.certid, cert: issue(serial: 3).first,
      client: "external", actor: "service")
    CatalogIndexer.refresh_consul
    assert_equal "delete", Certificate.find_by!(certid: record.certid, certificate_version: newer).rollout_status
  end

  test "invalid and stale status updates cannot change storage or audit" do
    record = store(issue.first)
    old_index = ConsulStore.status_snapshot(record)[:index]
    set_status(record, "norollout")
    count = AuditEvent.count
    assert_raises(Certificates::Error) { set_status(record, "delete", index: old_index) }
    assert_raises(Certificates::Error) { set_status(record, "unknown") }
    assert_raises(Certificates::Error) { set_status(record, "active", index: nil) }
    set_status(record, "norollout")
    assert_equal count, AuditEvent.count
    assert_equal "norollout", record.reload.rollout_status
  end

  test "filesystem entries have no status after reindex and file moves" do
    cert, key = issue
    previous = AreaConfiguration.configuration
    Dir.mktmpdir do |dir|
      configure_legacy_paths("zone_a" => dir)
      path = File.join(dir, "old.pem")
      content = cert.to_pem + key.private_to_pem
      File.write(path, content)
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      CatalogIndexer.run
      assert_equal "active", record.reload.rollout_status
      assert_not record.archived
      assert_nil ConsulStore.status_snapshot(record)
      assert_equal content, File.read(path)
      File.rename(path, File.join(dir, "new.pem"))
      CatalogIndexer.run
      assert_equal 2, Certificate.where(source: "filesystem", archived: false, rollout_status: "active").count
      assert_not_respond_to ConsulStore, :set_filesystem_status
      assert_empty AuditEvent.where(action: %w[archive status_change])
      other = store(cert, area: "zone_b")
      set_status(other, "norollout")
      assert_equal "active", record.reload.rollout_status
      assert_equal "norollout", other.reload.rollout_status
    end
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end
end
