require "test_helper"

class LegacyInventoryTest < ActiveSupport::TestCase
  setup do
    @previous_legacy = AreaConfiguration.configuration
    @directory = Dir.mktmpdir("cci-inventory-")
    configure_legacy_paths("zone_a" => @directory)
    @cert, = issue
    @path = File.join(@directory, "certificate.pem")
    File.write(@path, @cert.to_pem)
    CatalogIndexer.new.filesystem
    @record = Certificate.find_by!(source: "filesystem")
    ConsulStore.client.transaction([ConsulConnection.set("#{ConsulStore.prefix(@record.area)}/filesystem-statuses/#{@record.fingerprint}",
      { schema: "1", fingerprint: @record.fingerprint, status: "norollout" }, index: 0)])
    CatalogIndexer.refresh_consul
  end

  def legacy_snapshot(record)
    ConsulStore.client.get("#{ConsulStore.prefix(record.area)}/filesystem-statuses/#{record.fingerprint}")
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_legacy)
    FileUtils.remove_entry(@directory)
  end

  test "removing last disk copy retains Consul status catalog entry and audit" do
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert legacy_snapshot(@record)
    assert Certificate.exists?(@record.id)
    assert_equal 0, AuditEvent.where(action: "status_change").count
    assert_equal 0, ConsulStore.client.all("#{ConsulStore.namespace}/events/").size
  end

  test "copies renames and absent files preserve status and catalog records" do
    copy = File.join(@directory, "copy.pem")
    File.write(copy, @cert.to_pem)
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert_equal "active", Certificate.find_by!(source: "filesystem").rollout_status
    assert_nil ConsulStore.status_snapshot(@record)
    assert legacy_snapshot(@record)
    File.rename(copy, @path)
    CatalogIndexer.new.filesystem
    assert legacy_snapshot(@record)
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert legacy_snapshot(@record)
  end

  test "replacing a certificate or removing a bundle block retains previous identities" do
    other, = issue(serial: 2)
    File.write(@path, @cert.to_pem + other.to_pem)
    CatalogIndexer.new.filesystem
    other_record = Certificate.find_by!(source: "filesystem", fingerprint: Certificates::Codec.fingerprint(other))

    File.write(@path, other.to_pem)
    CatalogIndexer.new.filesystem
    assert legacy_snapshot(@record)
    assert_nil legacy_snapshot(other_record)
    assert_equal [@record.fingerprint, other_record.fingerprint].sort, Certificate.where(source: "filesystem").distinct.pluck(:fingerprint).sort
    assert_equal @record.fingerprint, @record.reload.fingerprint
    assert_equal 3, Certificate.where(source: "filesystem").count
    assert_raises(Certificates::Error) { CertificateMaterial.load(@record) }
  end

  test "missing directory or malformed PEM never causes cleanup" do
    File.delete(@path)
    configure_legacy_paths("zone_a" => File.join(@directory, "missing"))
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert legacy_snapshot(@record)
    assert Certificate.exists?(@record.id)
    configure_legacy_paths("zone_a" => @directory)
    File.write(@path, "-----BEGIN CERTIFICATE-----\nbroken\n")
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert legacy_snapshot(@record)
    assert Certificate.exists?(@record.id)
  end

  test "unreadable directory does not allow cleanup" do
    File.delete(@path)
    blocked = File.join(@directory, "blocked")
    Dir.mkdir(blocked)
    File.chmod(0, blocked)
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert legacy_snapshot(@record)
    assert Certificate.exists?(@record.id)
  ensure
    File.chmod(0700, blocked) if blocked
  end

  test "indexing retains all orphaned statuses and unrelated entries" do
    connection = ConsulStore.client
    base = ConsulStore.prefix(@record.area)
    65.times.each_slice(64) do |batch|
      connection.transaction(batch.map do |number|
        fingerprint = Digest::SHA256.hexdigest("orphan-#{number}")
        ConsulConnection.set("#{base}/filesystem-statuses/#{fingerprint}", { schema: "1", fingerprint: fingerprint, status: "delete" }, index: 0)
      end)
    end
    other_area = "#{ConsulStore.prefix('zone_b')}/filesystem-statuses/#{@record.fingerprint}"
    connection.transaction([ConsulConnection.set(other_area, { schema: "1", fingerprint: @record.fingerprint, status: "delete" }, index: 0)])
    imported = store(issue(serial: 3).first)
    CatalogIndexer.new.filesystem
    assert_equal 66, connection.all("#{base}/filesystem-statuses/").size
    assert connection.get(other_area)
    assert ConsulStore.get(imported.area, imported.source_id)
  end
end
