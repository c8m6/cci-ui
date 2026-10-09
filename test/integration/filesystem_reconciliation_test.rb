# frozen_string_literal: true

require "test_helper"

class FilesystemReconciliationIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @previous_configuration = AreaConfiguration.configuration
    @previous_environment = ENV.to_h.slice("CCI_CA_INVENTORY_ENABLED", "CCI_ZABBIX_INTEGRATION_ENABLED",
      "CCI_ZABBIX_INTEGRATION_TOKEN", "CCI_ZABBIX_CERTIFICATE_SOURCES")
    ENV["CCI_CA_INVENTORY_ENABLED"] = "true"
    ENV["CCI_ZABBIX_INTEGRATION_ENABLED"] = "true"
    ENV["CCI_ZABBIX_INTEGRATION_TOKEN"] = "synthetic-reconciliation-monitoring-token"
    ENV["CCI_ZABBIX_CERTIFICATE_SOURCES"] = "filesystem"
    @directory = Dir.mktmpdir("cci-reconciliation-integration-")
    configure_legacy_paths("zone_a" => @directory)
    @root, root_key = issue(name: "Reconciliation root", ca: true)
    leaf, = issue(name: "retained.example.test", issuer: @root, issuer_key: root_key)
    File.write(File.join(@directory, "root.pem"), @root.to_pem)
    9.times { |index| File.write(File.join(@directory, "leaf-#{index}.pem"), leaf.to_pem) }
    CatalogIndexer.run
    @record = Certificate.find_by!(source: "filesystem", source_id: "root.pem#0")
    @historical = AuditEvent.create!(action: "export_public", area: "zone_a", actor: "historical-operator",
      references: [@record.source_id], details: { outcome: "succeeded", fingerprint: @record.fingerprint })
    post local_login_path, params: { identity: "zone_a_writer" }
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_configuration)
    %w[CCI_CA_INVENTORY_ENABLED CCI_ZABBIX_INTEGRATION_ENABLED CCI_ZABBIX_INTEGRATION_TOKEN
      CCI_ZABBIX_CERTIFICATE_SOURCES].each { |key| ENV[key] = @previous_environment[key] }
    FileUtils.remove_entry(@directory)
  end

  test "confirmed cleanup removes active references exports and cached hosts while retaining audit history" do
    @record.update!(puppetdb_hosts: [{ "certname" => "node.example.test" }], puppetdb_checked_at: Time.current)
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal [@record.id], inventory.authorities.pluck("certificate_id")
    original_audit = @historical.attributes
    leaf = Certificate.find_by!(source_id: "leaf-0.pem#0")
    original_status = leaf.status_key
    File.delete(File.join(@directory, "root.pem"))
    CatalogIndexer.new.filesystem
    assert_equal 1, @record.reload.filesystem_missing_scans
    assert_includes monitored_ids, @record.id
    CatalogIndexer.new.filesystem
    assert_not Certificate.exists?(@record.id)
    assert_nil inventory.reload.checked_at
    assert_empty inventory.authorities
    assert_empty inventory.issues
    assert_not_includes monitored_ids, @record.id
    assert_equal 9, monitored_ids.size
    get root_path
    assert_response :success
    assert_select "a[href=?]", certificate_path(@record), count: 0
    get certificate_path(@record)
    assert_response :not_found
    post export_certificates_path, params: { ids: [@record.id], format_name: "pem" }
    assert_response :not_found
    get ca_inventory_path("zone_a")
    assert_response :success
    assert_empty YAML.safe_load(response.body)
    CatalogIndexer.run
    assert_empty inventory.reload.authorities
    assert_equal 1, inventory.issues.size
    assert_not_includes inventory.issues.pluck("certificate_id"), @record.id
    get ca_inventories_path
    assert_select "a[href=?]", certificate_path(@record), count: 0
    post export_certificates_path, params: { ids: [leaf.id], format_name: "pem" }
    assert_response :success
    assert_equal leaf.fingerprint, Certificates::Codec.fingerprint(OpenSSL::X509::Certificate.new(response.body))
    assert_equal original_status, leaf.reload.status_key
    assert_equal original_audit, @historical.reload.attributes
    deletion = AuditEvent.find_by!(action: "delete", actor: "indexer")
    assert_equal [@record.id], deletion.details.fetch("certificates").pluck("id")
    assert_not deletion.details.fetch("approved")
  end

  test "deleting a filesystem CA preserves its Consul duplicate and rebuilds references to the retained ID" do
    consul = store(@root, certid: "retained-ca")
    ENV["CCI_ZABBIX_CERTIFICATE_SOURCES"] = "both"
    File.delete(File.join(@directory, "root.pem"))
    2.times { CatalogIndexer.new.filesystem }
    CatalogIndexer.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal [consul.id], inventory.authorities.pluck("certificate_id")
    assert_empty inventory.issues
    assert_equal [{ "lookup" => "retained-ca" }], YAML.safe_load(inventory.hiera)
    assert_not_includes monitored_ids, @record.id
    assert_includes monitored_ids, consul.id
    assert_equal @root.to_der, CertificateMaterial.load(consul).fetch(:certificate).to_der
    assert @historical.reload
  end

  private

  def monitored_ids
    get "/integrations/zabbix", headers: { "Authorization" => "Bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")}" }
    assert_response :success
    response.parsed_body.fetch("certificates").pluck("id")
  end
end
