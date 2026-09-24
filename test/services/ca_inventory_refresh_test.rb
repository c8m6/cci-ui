# frozen_string_literal: true

require "test_helper"

class CaInventoryRefreshTest < ActiveSupport::TestCase
  setup do
    @enabled = ENV.fetch("CCI_CA_INVENTORY_ENABLED", nil)
    ENV["CCI_CA_INVENTORY_ENABLED"] = "true"
  end

  teardown do
    ENV["CCI_CA_INVENTORY_ENABLED"] = @enabled
  end

  test "index passes discover valid CAs for expired archived versions and retain legacy Hiera references" do
    root, root_key = issue(name: "Root", ca: true)
    intermediate, intermediate_key = issue(name: "Intermediate", ca: true, issuer: root, issuer_key: root_key)
    leaf, = issue(expired: true, issuer: intermediate, issuer_key: intermediate_key)
    store(root, certid: "root")
    store(intermediate, certid: "intermediate")
    store(leaf, certid: "leaf").update!(archived: true, rollout_status: "delete", active: false)
    Dir.mktmpdir do |directory|
      configure_legacy_paths("zone_a" => directory)
      File.write(File.join(directory, "root.pem"), root.to_pem)
      File.write(File.join(directory, "root.tag"), " legacy")
      CatalogIndexer.run
      inventory = CaInventory.find_by!(area: "zone_a")
      assert_equal 2, inventory.authorities.size
      assert_empty inventory.issues
      references = YAML.safe_load(inventory.hiera)
      assert_includes references, { "issuer" => "CN=Root, O=Test", "subject" => "CN=Root, O=Test legacy" }
      assert_includes references, { "lookup" => "intermediate" }
      assert_equal %w[intermediate root], inventory.authorities.pluck("kind").sort
      assert_not_nil CaInventory.find_by!(area: "zone_b").checked_at
    ensure
      configure_legacy_paths("zone_a" => TEST_LEGACY_ROOT)
    end
  end

  test "expired and future CAs resolve chains without exporting invalid CAs" do
    root, key = issue(name: "Expired", ca: true, expired: true)
    store(root, certid: "expired")
    leaf, = issue(issuer: root, issuer_key: key)
    store(leaf, certid: "leaf")
    impostor, = issue(name: "Expired", ca: true)
    impostor_record = store(impostor, certid: "impostor")
    future, future_key = issue(name: "Future", ca: true)
    future.not_before = 1.day.from_now
    future.sign(future_key, OpenSSL::Digest.new("SHA256"))
    store(future, certid: "future")
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal 3, inventory.authorities.size
    assert_equal [impostor_record.fingerprint], inventory.current_authorities.pluck("fingerprint")
    assert_empty inventory.issues
    assert_equal [{ "lookup" => "impostor" }], YAML.safe_load(inventory.hiera)
  end

  test "a matching issuer name without a matching signature remains incomplete" do
    root, key = issue(name: "Root", ca: true)
    impostor, = issue(name: "Root", ca: true, expired: true)
    store(impostor, certid: "impostor")
    store(issue(issuer: root, issuer_key: key).first, certid: "leaf")
    CaInventoryRefresh.run
    assert_equal ["missing"], CaInventory.find_by!(area: "zone_a").issues.pluck("reason")
  end

  test "issuer certificates require CA constraints and certificate signing key usage" do
    root, key = issue(name: "Not a CA")
    store(root, certid: "non-ca")
    leaf, = issue(issuer: root, issuer_key: key)
    store(leaf, certid: "leaf")
    restricted, restricted_key = issue(name: "Restricted", ca: true)
    factory = OpenSSL::X509::ExtensionFactory.new
    restricted.add_extension(factory.create_extension("keyUsage", "digitalSignature", true))
    restricted.sign(restricted_key, OpenSSL::Digest.new("SHA256"))
    store(restricted, certid: "restricted")
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_empty inventory.authorities
    assert_equal 3, inventory.issues.size
  end

  test "disabled scans preserve previous data without loading source material" do
    inventory = CaInventory.create!(area: "zone_a", checked_at: 1.day.ago)
    original = inventory.checked_at
    record = store(issue.first)
    record.update!(fingerprint: "unavailable")
    ENV["CCI_CA_INVENTORY_ENABLED"] = "false"
    CaInventoryRefresh.run
    assert_equal original, inventory.reload.checked_at
    assert_nil inventory.error_at
  end

  test "failed scans preserve complete snapshots and mark them stale" do
    record = store(issue(ca: true).first)
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    authorities = inventory.authorities
    checked = inventory.checked_at
    record.update!(fingerprint: "changed")
    assert_raises(Certificates::Error) { CaInventoryRefresh.run }
    inventory.reload
    assert_equal authorities, inventory.authorities
    assert_equal checked, inventory.checked_at
    assert_not_nil inventory.error_at
  end

  test "CAs that expire between scans immediately disappear from Hiera" do
    root, = issue(ca: true)
    store(root)
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    travel_to(root.not_after + 1) do
      assert_empty inventory.current_authorities
      assert_empty YAML.safe_load(inventory.hiera)
    end
  end

  test "issuer matching never crosses area boundaries" do
    root, key = issue(ca: true)
    store(root, area: "zone_b")
    leaf, = issue(issuer: root, issuer_key: key)
    store(leaf)
    CaInventoryRefresh.run
    assert_empty CaInventory.find_by!(area: "zone_a").authorities
    assert_equal 1, CaInventory.find_by!(area: "zone_a").issues.size
    assert_equal 1, CaInventory.find_by!(area: "zone_b").authorities.size
  end
  test "cyclic CA chains terminate and report the affected certificates" do
    first, first_key = issue(name: "First", ca: true)
    second, second_key = issue(name: "Second", ca: true, issuer: first, issuer_key: first_key)
    first.issuer = second.subject
    first.sign(second_key, OpenSSL::Digest.new("SHA256"))
    store(first, certid: "first")
    store(second, certid: "second")
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal 2, inventory.authorities.size
    assert_equal %w[cycle cycle], inventory.issues.pluck("reason")
  end

  test "a failed source index keeps the previous CA snapshot" do
    store(issue(ca: true).first)
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    checked = inventory.checked_at
    Dir.mktmpdir do |directory|
      configure_legacy_paths("zone_a" => File.join(directory, "unavailable"))
      assert_raises(Certificates::Error) { CatalogIndexer.run }
      assert_equal checked, inventory.reload.checked_at
      assert_not_nil inventory.error_at
    ensure
      configure_legacy_paths("zone_a" => TEST_LEGACY_ROOT)
    end
  end

  test "versionless lookups never export a historical CA as the active certificate" do
    old_ca, old_key = issue(name: "Old CA", ca: true)
    old_record = store(old_ca, certid: "rotating")
    leaf, = issue(issuer: old_ca, issuer_key: old_key, expired: true)
    store(leaf, certid: "old-leaf")
    active_ca, = issue(name: "New CA", ca: true)
    active_record = store(active_ca, certid: "rotating")
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal [old_record.fingerprint, active_record.fingerprint].sort, inventory.authorities.pluck("fingerprint").sort
    assert_equal [{ "lookup" => "rotating" }], YAML.safe_load(inventory.hiera)
    assert_empty inventory.issues
  end
end
