# frozen_string_literal: true

require "test_helper"

class CertificateIdentityTest < ActionDispatch::IntegrationTest
  test "current historical and archived versions show actual CertID and full fingerprints" do
    old = store(issue.first, certid: "real-id")
    current = store(issue(serial: 2).first, certid: "real-id")
    post local_login_path, params: { identity: "zone_a_reader" }
    [old, current].each do |record|
      get certificate_path(record)
      assert_response :success
      assert_equal({ "certid" => "real-id", "area" => "zone_a" }, YAML.safe_load(css_select("pre").last.text))
      [old, current].each { |version| assert_select ".version-row code", text: version.fingerprint }
      assert_select "dd code[data-clipboard-target=value]", text: record.fingerprint
      assert_select "button[data-action='clipboard#copy']"
    end
    ConsulStore.archive(current, actor: "test", expected_certid_index: ConsulStore.status_snapshot(current).fetch(:index))
    CatalogIndexer.refresh_consul
    get certificate_path(old)
    assert_equal({ "certid" => "real-id", "area" => "zone_a" }, YAML.safe_load(css_select("pre").last.text))
  end

  test "CA descendants start collapsed and remain visible to readers without changing exports" do
    previous = ENV.fetch("CCI_CA_INVENTORY_ENABLED", nil)
    ENV["CCI_CA_INVENTORY_ENABLED"] = "true"
    ca, key = issue(ca: true)
    record = store(ca, certid: "root")
    child = store(issue(issuer: ca, issuer_key: key).first, certid: "child")
    CaInventoryRefresh.run
    post local_login_path, params: { identity: "zone_a_reader" }
    get certificate_path(record)
    assert_select "details#issued-certificates:not([open])" do
      assert_select "a[href=?]", certificate_path(child)
    end
    get certificate_path(child)
    assert_select "#issued-certificates", count: 0
    ENV["CCI_CA_INVENTORY_ENABLED"] = "false"
    get certificate_path(record)
    assert_select "#issued-certificates", count: 0
  ensure
    ENV["CCI_CA_INVENTORY_ENABLED"] = previous
  end
end
