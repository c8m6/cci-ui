# frozen_string_literal: true

require "test_helper"

class HostInventoryPagesTest < ActionDispatch::IntegrationTest
  setup do
    @enabled = settings["puppetdb"]["enabled"]
    @algorithm = settings["puppetdb"]["inventory"]["fingerprint_algorithm"]
    @record = store(issue.first)
    @record.update!(puppetdb_hosts: %w[web.example.test other.example.test], puppetdb_checked_at: Time.current,
      puppetdb_paths: { "web.example.test" => ["/etc/tls/public.pem"] })
    settings["puppetdb"]["enabled"] = true
    post local_login_path, params: { identity: "zone_a_reader" }
    @connection = PuppetdbConnection.method(:new)
    PuppetdbConnection.define_singleton_method(:new) { raise "Host pages must not query PuppetDB" }
  end

  teardown do
    settings["puppetdb"]["enabled"] = @enabled
    settings["puppetdb"]["inventory"]["fingerprint_algorithm"] = @algorithm
    PuppetdbConnection.define_singleton_method(:new, @connection)
  end

  test "host views are gated and permission scoped without network requests" do
    foreign = @record.dup
    foreign.assign_attributes(area: "zone_b", source_id: "foreign/1", certid: "foreign", puppetdb_hosts: ["secret.example.test"])
    foreign.save!
    get hosts_path
    assert_response :success
    assert_select "a[href=?]", host_path(PuppetdbHosts.identifier("web.example.test")), text: "web.example.test"
    assert_not_includes response.body, "secret.example.test"
    get host_path(PuppetdbHosts.identifier("secret.example.test"))
    assert_response :not_found
    get hosts_path(area: "zone_b")
    assert_not_includes response.body, "secret.example.test"
    settings["puppetdb"]["enabled"] = false
    get certificates_path
    assert_select "a[href=?]", hosts_path, count: 0
    get hosts_path
    assert_response :not_found
    get host_path(PuppetdbHosts.identifier("web.example.test"))
    assert_response :not_found
  end

  test "details include every visible certificate full identity fingerprint and reported public path" do
    second = @record.dup
    second.assign_attributes(source_id: "other/1", certid: "other", puppetdb_hosts: ["web.example.test"], active: false, archived: true,
      rollout_status: "delete")
    second.save!
    get host_path(PuppetdbHosts.identifier("web.example.test"))
    assert_response :success
    assert_select "h1", text: "web.example.test"
    assert_select ".host-certificate", count: 2
    assert_select "code[data-clipboard-target=value]", text: @record.fingerprint, count: 2
    assert_includes response.body, "/etc/tls/public.pem"
    assert_includes response.body, "Archiviert"
    assert_includes response.body, "Alte Version"
    assert_select "a[href=?]", certificate_path(second)
  end

  test "substring search combines area and sync filters and preserves them through pagination" do
    @record.update!(puppetdb_hosts: Array.new(32) { |index| format("api-%02d.example.test", index) }, puppetdb_error_at: Time.current)
    get hosts_path(q: "API-", area: "zone_a", sync: "stale", page: 2)
    assert_response :success
    assert_select "tbody tr", count: 2
    assert_select ".pagination a" do |links|
      assert(links.any? do |link|
        link["href"].include?("q=API-") && link["href"].include?("area=zone_a") && link["href"].include?("sync=stale")
      end)
    end
    get hosts_path(q: "api-", area: "zone_b", sync: "stale")
    assert_select "tbody tr", count: 0
    get hosts_path(q: "api-", area: "zone_a", sync: "current")
    assert_select "tbody tr", count: 0
  end

  test "search pagination and stale filters use cached observations including missing SHA1" do
    @record.update!(puppetdb_hosts: Array.new(32) { |index| format("host%02d.example.test", index) })
    get hosts_path
    assert_select "tbody tr", count: 30
    get hosts_path(page: 2)
    assert_select "tbody tr", count: 2
    get hosts_path(q: "host31")
    assert_select "tbody tr", count: 1
    get hosts_path(q: "%")
    assert_select "tbody tr", count: 0
    @record.update!(puppetdb_error_at: Time.current)
    get hosts_path(sync: "current")
    assert_select "tbody tr", count: 0
    get host_path(PuppetdbHosts.identifier("host00.example.test"))
    assert_includes response.body, I18n.t("hosts.stale_note")
    @record.update!(puppetdb_error_at: nil, sha1_fingerprint: nil)
    settings["puppetdb"]["inventory"]["fingerprint_algorithm"] = "sha1"
    get hosts_path(sync: "stale")
    assert_select "tbody tr", count: 30
    @record.update!(puppetdb_hosts: [], puppetdb_paths: {})
    get host_path(PuppetdbHosts.identifier("host00.example.test"))
    assert_response :not_found
  end
end
