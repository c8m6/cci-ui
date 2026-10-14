# frozen_string_literal: true

require "test_helper"

class CaDescendantsTest < ActiveSupport::TestCase
  setup do
    @enabled = ENV.fetch("CCI_CA_INVENTORY_ENABLED", nil)
    ENV["CCI_CA_INVENTORY_ENABLED"] = "true"
    @identity = Identity.new(name: "reader", roles: ["zone_a_reader"])
  end

  teardown { ENV["CCI_CA_INVENTORY_ENABLED"] = @enabled }

  test "verified immediate and transitive children deduplicate DER and stay inside the area" do
    root, key = issue(name: "Root", ca: true)
    @root = store(root, certid: "root")
    intermediate, intermediate_key = issue(name: "Intermediate", ca: true, issuer: root, issuer_key: key)
    middle = store(intermediate, certid: "middle")
    store(intermediate, certid: "duplicate-middle")
    direct = store(issue(issuer: root, issuer_key: key).first, certid: "direct")
    leaf = store(issue(issuer: intermediate, issuer_key: intermediate_key).first, certid: "leaf")
    store(issue(issuer: root, issuer_key: key).first, certid: "foreign", area: "zone_b")
    store(issue(name: "Root", ca: true).first, certid: "impostor")
    CaInventoryRefresh.run
    result = descendants
    assert_equal [middle.fingerprint, direct.fingerprint].sort, result.records.map(&:fingerprint).sort
    assert_equal 2, result.total
    all = descendants(scope: "all")
    assert_equal 3, all.total
    assert_equal 2, all.depths.fetch(leaf.fingerprint)
    assert_equal "intermediate", all.kind(middle)
    assert_not all.ambiguous?(middle)
  end

  test "cross-signed issuers remain ambiguous and missing signers create no guessed edges" do
    root_a, key_a = issue(name: "Root A", ca: true)
    root_b, key_b = issue(name: "Root B", ca: true)
    @root = store(root_a, certid: "a")
    store(root_b, certid: "b")
    middle_a, key = issue(name: "Shared issuer", ca: true, issuer: root_a, issuer_key: key_a)
    middle_b = OpenSSL::X509::Certificate.new(middle_a.to_der)
    middle_b.issuer = root_b.subject
    middle_b.sign(key_b, OpenSSL::Digest.new("SHA256"))
    store(middle_a, certid: "middle-a")
    store(middle_b, certid: "middle-b")
    leaf = store(issue(issuer: middle_a, issuer_key: key).first, certid: "leaf")
    absent, absent_key = issue(name: "Absent", ca: true)
    missing = store(issue(issuer: absent, issuer_key: absent_key).first, certid: "missing")
    CaInventoryRefresh.run
    result = descendants(scope: "all")
    assert result.ambiguous?(leaf)
    assert_equal 2, result.total
    assert_not_includes result.depths, missing.fingerprint
    assert_empty result.inventory.issuer_edges.fetch(missing.fingerprint)
  end

  test "feature gate empty CAs missing files and pagination bound the visible graph" do
    @root = store(issue(ca: true).first)
    CaInventoryRefresh.run
    assert_equal 0, descendants.total
    graph = {}
    23.times do |index|
      record = @root.dup
      record.assign_attributes(source_id: "child-#{index}/1", certid: "child-#{index}", fingerprint: format("%064x", index))
      record.save!
      graph[record.fingerprint] = [@root.fingerprint]
    end
    CaInventory.find_by!(area: "zone_a").update!(issuer_edges: graph)
    assert_equal 20, descendants.records.size
    assert_equal 3, descendants(page: 2).records.size
    assert_equal 2, descendants(page: 999).page
    ENV["CCI_CA_INVENTORY_ENABLED"] = "false"
    assert_empty descendants.records
    assert_equal 0, descendants.total
  end

  private

  def descendants(**)
    CaDescendants.new(@root, identity: @identity, **)
  end
end
