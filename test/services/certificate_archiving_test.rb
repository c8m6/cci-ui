require "test_helper"
require_relative "../../examples/add_certificate"

class CertificateArchivingTest < ActiveSupport::TestCase
  def archive(record, index: ConsulStore.status_snapshot(record)&.fetch(:index) || 0)
    ConsulStore.archive(record, actor: "archive-writer", expected_certid_index: index)
    CatalogIndexer.refresh_consul
  end

  test "certid archive retains all material survives renewals and prevents reactivation" do
    cert, key = issue
    first = store(cert, key: key)
    second = store(issue(serial: 2).first)
    archive(first)
    assert first.reload.archived
    assert second.reload.archived
    assert_equal "delete", second.rollout_status
    assert second.active
    assert_equal cert.to_der, CertificateMaterial.load(first, private_key: true)[:certificate].to_der
    assert CertificateMaterial.load(first, private_key: true)[:key]
    renewed = store(issue(serial: 3).first)
    assert renewed.archived
    id = CertificateExample.add(area: first.area, certid: first.certid, cert: issue(serial: 4).first,
      client: "external", actor: "service")
    CatalogIndexer.refresh_consul
    assert Certificate.find_by!(certid: first.certid, certificate_version: id).archived
    assert_raises(Certificates::Error) { ConsulStore.activate(first.area, first.source_id, actor: "test") }
    assert_raises(Certificates::Error) do
      ConsulStore.set_status(first.area, first.source_id, status: "active", actor: "test",
        expected_certid_index: ConsulStore.status_snapshot(first)[:index])
    end
    Certificate.delete_all
    CatalogIndexer.refresh_consul
    assert_equal 4, Certificate.where(archived: true, rollout_status: "delete").count
    event = AuditEvent.find_by!(action: "archive")
    assert_equal "archive-writer", event.actor
    assert_equal "certid", event.details["scope"]
    assert_equal "active", event.details["previous_status"]
    assert_equal true, event.details["archived"]
    assert_includes event.details["comment"], "Puppet-Löschauftrag"
  end

  test "stale and missing confirmation indexes leave archive status and audit untouched" do
    record = store(issue.first)
    old = ConsulStore.status_snapshot(record)[:index]
    ConsulStore.set_status(record.area, record.source_id, status: "norollout", actor: "other",
      expected_certid_index: old)
    [old, nil].each do |index|
      assert_raises(Certificates::Error) { archive(record, index: index) }
    end
    CatalogIndexer.refresh_consul
    assert_not record.reload.archived
    assert_equal "norollout", record.rollout_status
    assert_empty AuditEvent.where(action: "archive")
    archive(record)
    assert_no_difference "AuditEvent.count" do
      archive(record)
    end
  end

  test "filesystem entries remain visible and cannot be archived even when their source disappears" do
    previous = AreaConfiguration.configuration
    Dir.mktmpdir do |dir|
      configure_legacy_paths("zone_a" => dir)
      cert, = issue
      path = File.join(dir, "old.pem")
      File.write(path, cert.to_pem)
      CatalogIndexer.run
      record = Certificate.find_by!(source: "filesystem")
      assert_raises(Certificates::Error) { archive(record) }
      File.delete(path)
      CatalogIndexer.run
      assert_raises(Certificates::Error) { archive(record) }
      assert_not record.reload.archived
      assert_equal "active", record.rollout_status
      assert_empty ConsulStore.client.all("#{ConsulStore.prefix(record.area)}/")
      assert_empty AuditEvent.where(action: "archive")
      configure_legacy_paths("zone_a" => File.join(dir, "offline"))
      assert_raises(Certificates::Error) { CatalogIndexer.run }
      assert Certificate.exists?(record.id)
    end
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end

  test "missing Consul versions and certids never delete catalog records or reset archived status" do
    record = store(issue.first)
    archive(record)
    base = ConsulStore.prefix(record.area)
    ConsulStore.client.transaction([
      { "Verb" => "delete", "Key" => "#{base}/keys/#{record.source_id}" },
      { "Verb" => "delete", "Key" => "#{base}/certids/#{record.certid}" }
    ])
    CatalogIndexer.run
    assert record.reload.archived
    assert_equal "delete", record.rollout_status
    assert_equal 1, AuditEvent.where(action: "archive").count
  end

  test "search includes archived historical versions without exposing another area" do
    old = store(issue(name: "old.example.test").first)
    current = store(issue(name: "new.example.test", serial: 2).first)
    other = store(issue(name: "hidden.example.test").first, area: "zone_b")
    archive(old)
    archive(other)
    visible = Certificate.visible_to(Identity.new(name: "reader", roles: ["zone_a_reader"]))
    assert_empty CertificateSearch.call(visible, {})
    assert_empty CertificateSearch.call(visible, { q: "  " })
    assert_equal [old.id], CertificateSearch.call(visible, { q: "old.example.test" }).pluck(:id)
    assert_equal [current.id], CertificateSearch.call(visible, { q: current.fingerprint }).pluck(:id)
    assert_equal 2, CertificateSearch.call(visible, { archived: "1" }).count
    assert_empty CertificateSearch.call(visible, { q: "hidden" })
  end
end
