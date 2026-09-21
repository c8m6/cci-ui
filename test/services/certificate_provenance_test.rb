require "test_helper"
require_relative "../../examples/add_certificate"

class CertificateProvenanceTest < ActiveSupport::TestCase
  test "provenance belongs to each version and survives activation" do
    first = store(issue.first, client: "cci-ui")
    second = store(issue(serial: 2).first, client: "acme-renewer")
    data = ConsulStore.get(first.area, first.source_id)
    assert_not data.key?("schema")
    assert_equal "cci-ui", data["client"]
    assert_equal "test", data["created_by"]
    ConsulStore.activate(first.area, first.source_id, actor: "another-user")
    CatalogIndexer.refresh_consul
    assert_equal "cci-ui", first.reload.client
    assert_equal "test", first.created_by
    assert_equal "acme-renewer", second.reload.client
    assert_equal "Externer Client: acme-renewer", second.origin_label
  end

  test "historical versions without provenance remain readable and clear stale metadata" do
    record = store(issue.first)
    path = "#{ConsulStore.prefix(record.area)}/keys/#{record.source_id}"
    data = ConsulStore.get(record.area, record.source_id).except("client", "created_by")
    ConsulStore.client.transaction([ConsulConnection.set(path, data)])
    CatalogIndexer.refresh_consul
    assert_nil record.reload.client
    assert_nil record.created_by
    assert_equal "Unbekannt (keine Client-Angabe)", record.origin_label
    assert_equal "Dateibestand", Certificate.new(source: "filesystem").origin_label
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace)
    assert_equal data["pem"], reader.fetch(area: record.area, certid: record.certid)
  end

  test "writers must explicitly identify themselves before any write" do
    cert, = issue
    args = { area: "zone_a", cert: cert, key: nil, tags: [], certid: "missing", actor: "test" }
    assert_raises(ArgumentError) { ConsulStore.save(**args) }
    [nil, "", " ", "a" * 121, "bad/client"].each do |client|
      assert_raises(Certificates::Error) { ConsulStore.save(**args, client: client) }
    end
    assert_raises(Certificates::Error) { ConsulStore.save(**args.merge(actor: " "), client: "test") }
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/")
  end

  test "standalone Ruby example writes compatible individual versions keys and provenance without audit events" do
    cert, key = issue
    args = { area: "zone_a", certid: "ruby-example", cert: cert, key: key,
      client: "acme-renewer", actor: "service-account", tags: ["Example"],
      prefix: ConsulStore.namespace }
    id = CertificateExample.add(**args)
    CatalogIndexer.refresh_consul
    record = Certificate.find_by!(certid: "ruby-example", certificate_version: id)
    assert_equal "acme-renewer", record.client
    assert_equal "service-account", record.created_by
    assert_equal ["Example"], record.tags
    assert CertificateMaterial.load(record, private_key: true)[:certificate].check_private_key(key)
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    assert_equal "acme-renewer", reader.fetch(area: "zone_a", certid: "ruby-example", field: "metadata")["client"]
    assert cert.check_private_key(OpenSSL::PKey.read(reader.fetch(area: "zone_a", certid: "ruby-example", field: "private_key")))
    assert_empty AuditEvent.all
    renewed = CertificateExample.add(**args.merge(cert: issue(serial: 2).first, key: nil, client: "other-client"))
    CatalogIndexer.refresh_consul
    assert_not record.reload.active
    assert Certificate.find_by!(certid: "ruby-example", certificate_version: renewed).active
    assert_empty AuditEvent.all
  end
end
