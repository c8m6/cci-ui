# frozen_string_literal: true

require "test_helper"

class PuppetdbHostsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_enabled = settings["puppetdb"]["enabled"]
    @previous_algorithm = settings["puppetdb"]["inventory"]["fingerprint_algorithm"]
    @previous_connection = PuppetdbConnection.method(:new)
    connection = Object.new
    connection.define_singleton_method(:inventory) { |_query| [] }
    PuppetdbConnection.define_singleton_method(:new) { connection }
    @record = store(issue.first)
    post local_login_path, params: { identity: "zone_a_reader" }
  end

  teardown do
    PuppetdbConnection.define_singleton_method(:new, @previous_connection)
    settings["puppetdb"]["enabled"] = @previous_enabled
    settings["puppetdb"]["inventory"]["fingerprint_algorithm"] = @previous_algorithm
  end

  test "host counts and detail lists are optional and use stored inventory" do
    @record.update!(puppetdb_hosts: %w[app01.example.test app02.example.test], puppetdb_checked_at: Time.current)
    settings["puppetdb"]["enabled"] = false
    get certificates_path
    assert_select "th", text: "Hosts", count: 0
    get certificate_path(@record)
    assert_select "#puppetdb-hosts", count: 0
    settings["puppetdb"]["enabled"] = true
    get certificates_path
    assert_select "th", text: "Hosts", count: 1
    assert_select ".puppetdb-host-count a", text: "2"
    get certificate_path(@record)
    assert_response :success
    assert_select "#puppetdb-hosts li", count: 2
    assert_select "#puppetdb-hosts li", text: "app01.example.test"
    assert_includes response.body, "keine Live-Prüfung"
  end

  test "unknown empty and failed queries remain distinguishable" do
    settings["puppetdb"]["enabled"] = true
    get certificates_path
    assert_select ".puppetdb-host-count", text: "–"
    get certificate_path(@record)
    assert_includes response.body, "noch keine erfolgreiche PuppetDB-Abfrage"
    @record.update!(puppetdb_checked_at: Time.current)
    get certificates_path
    assert_select ".puppetdb-host-count a", text: "0"
    get certificate_path(@record)
    assert_includes response.body, "auf keinem Host gemeldet"
    @record.update!(puppetdb_hosts: ["cached.example.test"], puppetdb_error_at: Time.current)
    get certificates_path
    assert_select ".puppetdb-host-count a", text: "1"
    assert_includes response.body, "Abfrage fehlgeschlagen"
    get certificate_path(@record)
    assert_select "#puppetdb-hosts li", text: "cached.example.test"
    assert_includes response.body, "können veraltet sein"
  end

  test "archived records show escaped hostnames while foreign certificate details stay inaccessible" do
    settings["puppetdb"]["enabled"] = true
    host = "<script>alert(1)</script>"
    @record.update!(archived: true, rollout_status: "delete", puppetdb_hosts: [host], puppetdb_checked_at: Time.current)
    get certificate_path(@record)
    assert_select "#puppetdb-hosts li", text: host
    assert_select "#puppetdb-hosts script", count: 0
    hidden = store(issue(serial: 2).first, area: "zone_b")
    get certificate_path(hidden)
    assert_response :not_found
  end

  test "missing configured digest is shown as unknown rather than a confirmed zero hosts" do
    settings["puppetdb"]["enabled"] = true
    settings["puppetdb"]["inventory"]["fingerprint_algorithm"] = "sha1"
    @record.update!(sha1_fingerprint: nil)
    get certificates_path
    assert_select ".puppetdb-host-count a", count: 0
    assert_includes response.body, "Fingerprint fehlt"
    get certificate_path(@record)
    assert_includes response.body, "Fingerprint für den gewählten PuppetDB-Abgleich fehlt"
    assert_includes response.body, "noch keine erfolgreiche PuppetDB-Abfrage"
  end
end
