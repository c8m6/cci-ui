require "test_helper"

class LegacyInventoryTest < ActiveSupport::TestCase
  setup do
    @previous_legacy = ENV["LEGACY_PATH"]
    @directory = Dir.mktmpdir("cci-inventory-")
    ENV["LEGACY_PATH"] = @directory
    @cert, = issue
    @path = File.join(@directory, "certificate.pem")
    File.write(@path, @cert.to_pem)
    CatalogIndexer.new.filesystem
    @record = Certificate.find_by!(source: "filesystem")
    ConsulStore.set_filesystem_status(@record, status: "norollout", actor: "test", expected_lookup_index: 0)
    CatalogIndexer.refresh_consul
  end

  teardown do
    ENV["LEGACY_PATH"] = @previous_legacy
    FileUtils.remove_entry(@directory)
  end

  test "removing last disk copy removes Consul status and catalog entry but retains audit" do
    # The cleanup must work even after the PostgreSQL index was lost.
    Certificate.where(source: "filesystem").delete_all
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert_nil ConsulStore.status_snapshot(@record)
    assert_empty Certificate.where(source: "filesystem")
    assert_equal 1, AuditEvent.where(action: "status_change").count
    assert_equal 1, ConsulStore.client.all("#{ConsulStore.namespace}/events/").size
  end

  test "a remaining copy or rename preserves status until the last copy disappears" do
    copy = File.join(@directory, "copy.pem")
    File.write(copy, @cert.to_pem)
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert_equal "norollout", Certificate.find_by!(source: "filesystem").rollout_status
    assert ConsulStore.status_snapshot(@record)
    File.rename(copy, @path)
    CatalogIndexer.new.filesystem
    assert ConsulStore.status_snapshot(@record)
    File.delete(@path)
    CatalogIndexer.new.filesystem
    assert_nil ConsulStore.status_snapshot(@record)
  end

  test "replacing a certificate or removing a bundle block prunes only absent fingerprints" do
    other, = issue(serial: 2)
    File.write(@path, @cert.to_pem + other.to_pem)
    CatalogIndexer.new.filesystem
    other_record = Certificate.find_by!(source: "filesystem", fingerprint: Certificates::Codec.fingerprint(other))
    ConsulStore.set_filesystem_status(other_record, status: "delete", actor: "test", expected_lookup_index: 0)
    File.write(@path, other.to_pem)
    CatalogIndexer.new.filesystem
    assert_nil ConsulStore.status_snapshot(@record)
    assert ConsulStore.status_snapshot(other_record)
    assert_equal [other_record.fingerprint], Certificate.where(source: "filesystem").pluck(:fingerprint)
  end

  test "missing directory or malformed PEM never causes cleanup" do
    File.delete(@path)
    ENV["LEGACY_PATH"] = File.join(@directory, "missing")
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert ConsulStore.status_snapshot(@record)
    assert Certificate.exists?(@record.id)
    ENV["LEGACY_PATH"] = @directory
    File.write(@path, "-----BEGIN CERTIFICATE-----\nbroken\n")
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert ConsulStore.status_snapshot(@record)
    assert Certificate.exists?(@record.id)
  end

  test "unreadable directory does not allow cleanup" do
    File.delete(@path)
    blocked = File.join(@directory, "blocked")
    Dir.mkdir(blocked)
    File.chmod(0, blocked)
    assert_raises(Certificates::Error) { CatalogIndexer.new.filesystem }
    assert ConsulStore.status_snapshot(@record)
    assert Certificate.exists?(@record.id)
  ensure
    File.chmod(0700, blocked) if blocked
  end

  test "cleanup uses CAS and preserves a concurrent status change" do
    connection = ConsulStore.client
    entries = ConsulStore.filesystem_status_entries(connection, @record.area)
    current = ConsulStore.status_snapshot(@record)
    ConsulStore.set_filesystem_status(@record, status: "delete", actor: "another-writer", expected_lookup_index: current[:index])
    assert_raises(ConsulConnection::Conflict) { ConsulStore.prune_filesystem_statuses(connection, entries, Set.new) }
    assert_equal "delete", JSON.parse(ConsulStore.status_snapshot(@record)[:value])["status"]
  end

  test "cleanup handles more than one Consul transaction and leaves unrelated entries intact" do
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
    assert_equal 1, ConsulStore.filesystem_status_entries(connection, @record.area).size
    assert connection.get(other_area)
    assert ConsulStore.get(imported.area, imported.source_id)
  end
end
