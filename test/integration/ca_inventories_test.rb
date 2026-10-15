# frozen_string_literal: true

require "test_helper"

class CaInventoriesTest < ActionDispatch::IntegrationTest
  setup { post local_login_path, params: { identity: "zone_a_reader" } }

  test "standalone overview has no route or navigation item" do
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/ca_inventories") }
    get "/ca_inventories"
    assert_response :not_found
    get certificates_path
    assert_response :success
    assert_select "a[href='/ca_inventories']", count: 0
  end

  test "existing Hiera download preserves source format and area permissions" do
    store(issue(name: "Visible CA", ca: true).first)
    store(issue(name: "Hidden CA", ca: true).first, area: "zone_b")
    CaInventoryRefresh.run
    get ca_inventory_path("zone_a")
    assert_response :success
    assert_equal "application/yaml", response.media_type
    assert_includes response.headers["Content-Disposition"], "ca-certificates-zone_a.yaml"
    assert_equal [{ "lookup" => "test" }], YAML.safe_load(response.body)
    get ca_inventory_path("zone_b")
    assert_response :not_found
  end

  test "Hiera export excludes invalid CAs while retaining the complete inventory" do
    root, key = issue(name: "Expired root", ca: true, expired: true)
    intermediate, = issue(name: "Intermediate", ca: true, issuer: root, issuer_key: key)
    store(root, certid: "root")
    store(intermediate, certid: "intermediate")
    CaInventoryRefresh.run
    inventory = CaInventory.find_by!(area: "zone_a")
    assert_equal 2, inventory.authorities.size
    assert_empty inventory.issues
    get ca_inventory_path("zone_a")
    assert_equal [{ "lookup" => "intermediate" }], YAML.safe_load(response.body)
    CaInventoryRefresh.failed!
    get ca_inventory_path("zone_a")
    assert_equal [{ "lookup" => "intermediate" }], YAML.safe_load(response.body)
  end
end
