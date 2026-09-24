# frozen_string_literal: true

require "test_helper"

class CaInventoriesTest < ActionDispatch::IntegrationTest
  setup do
    @enabled = ENV.fetch("CCI_CA_INVENTORY_ENABLED", nil)
    ENV["CCI_CA_INVENTORY_ENABLED"] = "true"
    post local_login_path, params: { identity: "zone_a_reader" }
  end

  teardown do
    ENV["CCI_CA_INVENTORY_ENABLED"] = @enabled
  end

  test "page and YAML downloads are optional and area scoped" do
    store(issue(name: "Visible CA", ca: true).first)
    store(issue(name: "Hidden CA", ca: true).first, area: "zone_b")
    CaInventoryRefresh.run
    get ca_inventories_path
    assert_response :success
    assert_includes response.body, "Visible CA"
    assert_not_includes response.body, "Hidden CA"
    get ca_inventory_path("zone_a")
    assert_response :success
    assert_equal [{ "lookup" => "test" }], YAML.safe_load(response.body)
    get ca_inventory_path("zone_b")
    assert_response :not_found
    ENV["CCI_CA_INVENTORY_ENABLED"] = "false"
    get ca_inventories_path
    assert_response :not_found
    get ca_inventory_path("zone_a")
    assert_response :not_found
    get root_path
    assert_select "a[href=?]", ca_inventories_path, count: 0
  end

  test "intermediates stay nested under expired roots with overview validity badges" do
    root, key = issue(name: "Z Root", ca: true, expired: true)
    intermediate, intermediate_key = issue(name: "A Intermediate", ca: true, issuer: root, issuer_key: key)
    nested, = issue(name: "B Intermediate", ca: true, issuer: intermediate, issuer_key: intermediate_key)
    store(root, certid: "root")
    store(intermediate, certid: "intermediate")
    store(nested, certid: "nested")
    store(issue(name: "Missing issuer", expired: true).first, certid: "missing")
    CaInventoryRefresh.run
    get ca_inventories_path
    assert_select "main.full-width"
    assert_select "#zone_a-authorities-panel .ca-hierarchy-group", count: 1 do
      assert_select "tr[data-depth='0'] a", text: /Z Root/
      assert_select "tr[data-depth='0'] .badge.danger", text: "Abgelaufen"
      assert_select "tr[data-depth='1'] a", text: /A Intermediate/
      assert_select "tr[data-depth='2'] a", text: /B Intermediate/
    end
    assert_select "#zone_a-issues-panel tbody tr", count: 1 do
      assert_select "a", text: /Missing issuer/
      assert_select ".badge.danger", text: "Abgelaufen"
    end
  end

  test "pending empty failed and incomplete snapshots have distinct messages in both languages" do
    get ca_inventories_path
    assert_includes response.body, "Noch kein erfolgreicher CA-Scan"
    store(issue(name: "<script>missing").first)
    CaInventoryRefresh.run
    CaInventory.find_by!(area: "zone_a").update!(error_at: Time.current)
    get ca_inventories_path
    assert_includes response.body, "kann veraltet sein"
    assert_includes response.body, "Keine CA-Zertifikate"
    assert_includes response.body, "Keine CA mit passendem Aussteller"
    assert_select "main script", count: 0
    post locale_path, params: { locale: "en", return_to: ca_inventories_path }
    get ca_inventories_path
    assert_response :success
    assert_includes response.body, "CA certificates"
    assert_includes response.body, "No CA with a matching issuer"
  end
end
