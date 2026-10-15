# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class DashboardTest < ActionDispatch::IntegrationTest
  include CsrFixtures

  test "dashboard scopes counts area rows and expiration links without external requests" do
    current = store(issue.first)
    expired = store(issue(name: "expired.example.test", expired: true).first, certid: "expired")
    store(issue(name: "hidden.example.test").first, area: "zone_b")
    current.update!(not_after: 2.days.from_now, puppetdb_hosts: %w[web.example.test shared.example.test])
    create_csr
    settings["puppetdb"]["enabled"] = true
    post local_login_path, params: { identity: "zone_a_reader" }
    original = ConsulStore.method(:client)
    ConsulStore.define_singleton_method(:client) { |*| raise "Dashboard must not query Consul" }
    get root_path
    assert_response :success
    assert_select '[data-stat="total"] strong', text: "2"
    assert_select '[data-stat="valid"] strong', text: "1"
    assert_select '[data-stat="expiring"] strong', text: "1"
    assert_select '[data-stat="expired"] strong', text: "1"
    assert_select '[data-stat="hosts"] strong', text: "2"
    assert_select '[data-stat="open_csrs"] strong', text: "0"
    assert_select "a[href=?]", certificate_path(expired)
    assert_not_includes response.body, "hidden.example.test"
    assert_not_includes response.body, "Zone B"
    assert_includes response.body, I18n.t("dashboard.unknown")
  ensure
    ConsulStore.define_singleton_method(:client, original) if original
  end

  test "navigation is ordered roles are informational and dashboard has no navigation entry" do
    post local_login_path, params: { identity: "all:writer" }
    settings["puppetdb"]["enabled"] = true
    get root_path
    assert_select "nav .nav-item" do |links|
      assert_equal([certificates_path, hosts_path, new_import_path], links.map { |link| link["href"] })
    end
    assert_select "a.brand[href=?]", root_path
    assert_select ".sidebar-roles:not([open])"
    assert_select ".sidebar-roles li", text: "zone_a_writer", count: 1
    assert_select ".sidebar-roles li", text: "zone_b_writer", count: 1
    assert_select "nav a[href=?]", root_path, count: 0
    get certificates_path(area: "zone_a")
    assert_select "select[name=area] option[selected][value=zone_a]"
  end

  test "CSR-only dashboard counts retained open requests without granting certificate access" do
    csr = create_csr
    post local_login_path, params: { identity: "zone_a_csr" }
    get root_path
    assert_select '[data-stat="total"] strong', text: "0"
    assert_select '[data-stat="open_csrs"] strong', text: "1"
    CsrWorkflow.delete(csr, identity: csr_identity, confirmed: true)
    get root_path
    assert_select '[data-stat="open_csrs"] strong', text: "0"
  end
end
