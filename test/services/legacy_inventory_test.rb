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
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_legacy)
    FileUtils.remove_entry(@directory)
  end

  test "removing last disk copy retains catalog entry without Consul state" do
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert Certificate.exists?(@record.id)
    assert_equal 0, AuditEvent.where(action: "status_change").count
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/")
  end

  test "copies renames and absent files preserve catalog records" do
    copy = File.join(@directory, "copy.pem")
    File.write(copy, @cert.to_pem)
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert_equal "active", Certificate.find_by!(source: "filesystem").rollout_status
    assert_nil ConsulStore.status_snapshot(@record)
    File.rename(copy, @path)
    CatalogIndexer.new.filesystem
    File.delete(@path)
    CatalogIndexer.new.filesystem
  end

  test "replacing a certificate or removing a bundle block retains previous identities" do
    other, = issue(serial: 2)
    File.write(@path, @cert.to_pem + other.to_pem)
    CatalogIndexer.new.filesystem
    other_record = Certificate.find_by!(source: "filesystem", fingerprint: Certificates::Codec.fingerprint(other))

    File.write(@path, other.to_pem)
    CatalogIndexer.new.filesystem
    assert_equal [@record.fingerprint, other_record.fingerprint].sort, Certificate.where(source: "filesystem").distinct.pluck(:fingerprint).sort
    assert_equal @record.fingerprint, @record.reload.fingerprint
    assert_equal 3, Certificate.where(source: "filesystem").count
    assert_raises(Certificates::Error) { CertificateMaterial.load(@record) }
  end

  test "missing directory or malformed PEM never causes cleanup" do
    File.delete(@path)
    configure_legacy_paths("zone_a" => File.join(@directory, "missing"))
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert Certificate.exists?(@record.id)
    configure_legacy_paths("zone_a" => @directory)
    File.write(@path, "-----BEGIN CERTIFICATE-----\nbroken\n")
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert Certificate.exists?(@record.id)
  end

  test "unreadable directory does not allow cleanup" do
    File.delete(@path)
    blocked = File.join(@directory, "blocked")
    Dir.mkdir(blocked)
    File.chmod(0, blocked)
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert Certificate.exists?(@record.id)
  ensure
    File.chmod(0700, blocked) if blocked
  end

end
