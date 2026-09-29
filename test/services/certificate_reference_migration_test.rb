# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260929000100_normalize_certificate_acme_clients")

class CertificateReferenceMigrationTest < ActiveSupport::TestCase
  test "migration retains old certificates and user identities and rollback does not invent old references" do
    cert = issue.first
    automated = store(cert, certid: "automated", client: "puppet")
    user = store(cert, certid: "manual", client: "cci-ui")
    user.update!(created_by: "ACME-user")
    migration = NormalizeCertificateAcmeClients.new
    migration.down
    automated.update_columns(client: "ACME-renewer", created_by: "original-service")
    migration.up
    assert_equal 2, Certificate.count
    assert_equal "puppet", automated.reload.client
    assert_equal "original-service", automated.created_by
    assert_equal "cci-ui", user.reload.client
    assert_equal "ACME-user", user.created_by
    assert_equal "manual", user.renewal_mode
    migration.down
    assert_equal "puppet", automated.reload.client
    assert_equal 2, Certificate.count
    migration.up
    assert_equal "puppet", automated.reload.client
  end

  test "model database and shared writer reject new obsolete client references" do
    record = store(issue.first)
    %w[acme ACME-renewer puppet-acme acme.sh].each do |client|
      record.client = client
      assert_not record.valid?
      assert_includes record.errors[:client].join, "puppet"
      assert_raises(ActiveRecord::StatementInvalid) do
        Certificate.transaction(requires_new: true) { record.update_columns(client: client) }
      end
      assert_raises(Certificates::Error) { store(issue.first, certid: "obsolete", client: client) }
    end
    assert_equal 1, Certificate.count
  end

  test "indexer and reader translate retained legacy Consul provenance without rewriting source or actor" do
    record = store(issue.first, client: "puppet")
    path = "#{ConsulStore.prefix(record.area)}/certs/#{record.source_id}"
    data = ConsulStore.get(record.area, record.source_id).merge("client" => "puppet-acme", "created_by" => "original-actor")
    ConsulStore.client.transaction([ConsulConnection.set(path, data)])
    2.times do
      CatalogIndexer.refresh_consul
      assert_equal "puppet", record.reload.client
      assert_equal "original-actor", record.created_by
      assert_equal "puppet", record.renewal_mode
    end
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace)
    metadata = reader.read_certificate(area: record.area, certid: record.certid, field: "metadata")
    assert_equal "puppet", metadata.fetch("client")
    assert_equal "original-actor", metadata.fetch("created_by")
    assert_equal "puppet-acme", ConsulStore.get(record.area, record.source_id).fetch("client")
    assert_equal 1, Certificate.count
  end
end
