require "test_helper"

class MultipleLegacySourcesTest < ActiveSupport::TestCase
  setup do
    @previous_configuration = AreaConfiguration.configuration
    @directory = Dir.mktmpdir("cci-multiple-legacy-")
    @paths = %w[zone_a zone_b].to_h { |area| [area, File.join(@directory, area)] }
    @paths.each_value { |path| Dir.mkdir(path) }
    configure_paths(@paths)
    @cert, @key = issue(name: "shared.example.test")
    @paths.each do |area, path|
      File.write(File.join(path, "same.pem"), @cert.to_pem)
      File.write(File.join(path, "same.key"), @key.private_to_pem)
      File.write(File.join(path, "same.tag"), "_#{area}")
    end
    CatalogIndexer.run
    @records = Certificate.where(source: "filesystem").index_by(&:area)
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_configuration)
    FileUtils.remove_entry(@directory)
  end

  def configure_paths(paths)
    AreaConfiguration.instance_variable_set(:@configuration,
      @previous_configuration.merge("legacy_paths" => paths))
  end

  def set_status(area, status)
    record = @records.fetch(area)
    ConsulStore.set_filesystem_status(record, status: status, actor: "test",
      expected_lookup_index: ConsulStore.status_snapshot(record)&.fetch(:index) || 0)
    CatalogIndexer.refresh_consul
  end

  test "same fingerprint and relative path have independent zone status and cleanup" do
    assert_equal %w[zone_a zone_b], @records.keys.sort
    assert_equal ["same.pem#0"], @records.values.map(&:source_id).uniq
    set_status("zone_a", "norollout")
    set_status("zone_b", "delete")
    assert_equal "norollout", @records.fetch("zone_a").reload.rollout_status
    assert_equal "delete", @records.fetch("zone_b").reload.rollout_status
    File.delete(File.join(@paths.fetch("zone_a"), "same.pem"))
    CatalogIndexer.run
    assert_nil ConsulStore.status_snapshot(@records.fetch("zone_a"))
    assert ConsulStore.status_snapshot(@records.fetch("zone_b"))
    assert_equal ["zone_b"], Certificate.where(source: "filesystem").pluck(:area)
    assert_equal 2, AuditEvent.where(action: "status_change").count
  end

  test "material private keys and tags resolve in the record zone" do
    different, different_key = issue(name: "zone-b.example.test", serial: 2)
    File.write(File.join(@paths.fetch("zone_b"), "same.pem"), different.to_pem)
    File.write(File.join(@paths.fetch("zone_b"), "same.key"), different_key.private_to_pem)
    CatalogIndexer.run
    @records.each do |area, record|
      record.reload
      material = CertificateMaterial.load(record, private_key: true)
      expected = area == "zone_a" ? @cert : different
      assert_equal expected.to_der, material.fetch(:certificate).to_der
      assert expected.check_private_key(material.fetch(:key))
      assert_equal ["_#{area}"], record.tags
      snippet = YAML.safe_load(HieraSnippet.for(record, material.fetch(:certificate)))
      assert snippet.fetch("subject").end_with?("_#{area}")
    end
    assert_raises(ArgumentError) { LegacyStore.root }
    File.symlink(File.join(@paths.fetch("zone_b"), "same.pem"), File.join(@paths.fetch("zone_a"), "escape.pem"))
    assert_raises(Certificates::Error) { LegacyStore.certificates("escape.pem", area: "zone_a") }
    assert_raises(Certificates::Error) { LegacyStore.certificates("../zone_b/same.pem", area: "zone_a") }
  end

  test "an unavailable first zone preserves its records while other zones and Consul refresh" do
    set_status("zone_a", "norollout")
    set_status("zone_b", "delete")
    File.rename(@paths.fetch("zone_a"), File.join(@directory, "offline"))
    File.delete(File.join(@paths.fetch("zone_b"), "same.pem"))
    new_cert, = issue(serial: 3)
    id = ConsulStore.save(area: "zone_b", lookup: "new-consul", cert: new_cert, key: nil,
      chain: [], tags: [], actor: "test", client: "test-client")
    assert_raises(Certificates::Error) { CatalogIndexer.run }
    assert Certificate.exists?(@records.fetch("zone_a").id)
    assert ConsulStore.status_snapshot(@records.fetch("zone_a"))
    assert_not Certificate.exists?(@records.fetch("zone_b").id)
    assert_nil ConsulStore.status_snapshot(@records.fetch("zone_b"))
    assert Certificate.exists?(source: "consul", source_id: id)
    assert_raises(Certificates::Error) { LegacyStore.reject_duplicates!([Certificates::Codec.fingerprint(new_cert)]) }
  end

  test "one shared directory can intentionally be assigned to multiple zones" do
    configure_paths("zone_a" => @paths.fetch("zone_a"), "zone_b" => @paths.fetch("zone_a"))
    CatalogIndexer.run
    assert_equal %w[zone_a zone_b], Certificate.where(source: "filesystem").order(:area).pluck(:area)
    assert_equal @cert.to_der, CertificateMaterial.load(@records.fetch("zone_b"))[:certificate].to_der
    set_status("zone_a", "delete")
    assert_equal "active", @records.fetch("zone_b").reload.rollout_status
  end

  test "removing a mapping blocks stale material and removes catalog rows without deleting status" do
    set_status("zone_b", "norollout")
    configure_paths("zone_a" => @paths.fetch("zone_a"))
    assert_raises(Certificates::Error) { CertificateMaterial.load(@records.fetch("zone_b")) }
    CatalogIndexer.run
    assert_equal ["zone_a"], Certificate.where(source: "filesystem").pluck(:area)
    assert ConsulStore.status_snapshot(@records.fetch("zone_b"))
    assert File.exist?(File.join(@paths.fetch("zone_b"), "same.pem"))
  end

  test "empty mappings explicitly disable legacy inventories" do
    configure_paths({})
    CatalogIndexer.run
    assert_empty Certificate.where(source: "filesystem")
    assert_nil LegacyStore.reject_duplicates!([Certificates::Codec.fingerprint(@cert)])
  end
end
