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
  end

  test "root and intermediate descendants distinguish pending empty and failed scans in both languages" do
    ca, key = issue(name: "Root", ca: true)
    root = store(ca, certid: "root")
    middle = store(issue(name: "Intermediate", ca: true, issuer: ca, issuer_key: key).first, certid: "middle")
    post local_login_path, params: { identity: "zone_a_reader" }
    %i[de en].each do |locale|
      post locale_path, params: { locale: locale, return_to: certificate_path(root) }
      CaInventory.delete_all
      [root, middle].each { |record| assert_descendant_state(record, :pending, locale) }
      CaInventoryRefresh.failed!
      [root, middle].each do |record|
        assert_descendant_state(record, :stale, locale)
        assert_includes response.body, I18n.t("ca_inventory.graph_pending", locale: locale)
      end
      CaInventoryRefresh.run
      assert_descendant_state(middle, :empty, locale)
      get certificate_path(root)
      assert_select "#issued-certificates a[href=?]", certificate_path(middle)
      CaInventoryRefresh.failed!
      assert_descendant_state(root, :stale, locale)
      assert_select "#issued-certificates a[href=?]", certificate_path(middle)
      assert_descendant_state(middle, :stale, locale)
      assert_not_includes response.body, I18n.t("ca_inventory.graph_empty", locale: locale)
      CaInventoryRefresh.run
      assert_descendant_state(middle, :empty, locale)
    end
  end

  test "an empty standalone root still has a collapsed descendants panel" do
    record = store(issue(ca: true).first)
    CaInventoryRefresh.run
    post local_login_path, params: { identity: "zone_a_reader" }
    assert_descendant_state(record, :empty, :de)
  end

  private

  def assert_descendant_state(record, state, locale)
    get certificate_path(record)
    assert_response :success
    assert_select "details#issued-certificates:not([open])" do
      assert_select "[role=status]", text: I18n.t("ca_inventory.graph_#{state}", locale: locale)
    end
    assert_select "#issued-certificates .pagination", count: 0 if %i[empty pending].include?(state)
  end
end
