# frozen_string_literal: true

require "test_helper"

class PuppetdbHostsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_enabled = ENV.fetch("PUPPETDB_ENABLED", nil)
    @previous_algorithm = ENV.fetch("PUPPETDB_FINGERPRINT_ALGORITHM", nil)
    @previous_connection = PuppetdbConnection.method(:new)
    connection = Object.new
    connection.define_singleton_method(:inventory) { |_query| [] }
    PuppetdbConnection.define_singleton_method(:new) { connection }
    @record = store(issue.first)
    post local_login_path, params: { identity: "zone_a_reader" }
  end

  teardown do
    PuppetdbConnection.define_singleton_method(:new, @previous_connection)
    ENV["PUPPETDB_ENABLED"] = @previous_enabled
    ENV["PUPPETDB_FINGERPRINT_ALGORITHM"] = @previous_algorithm
  end

  test "host counts and detail lists are optional and use stored inventory" do
    @record.update!(puppetdb_hosts: %w[app01.example.test app02.example.test], puppetdb_checked_at: Time.current)
    ENV["PUPPETDB_ENABLED"] = "false"
    get root_path
    assert_select "th", text: "Hosts", count: 0
    get certificate_path(@record)
    assert_select "#puppetdb-hosts", count: 0
    ENV["PUPPETDB_ENABLED"] = "true"
    get root_path
    assert_select "th", text: "Hosts", count: 1
    assert_select ".puppetdb-host-count a", text: "2"
    get certificate_path(@record)
    assert_response :success
    assert_select "#puppetdb-hosts li", count: 2
    assert_select "#puppetdb-hosts li", text: "app01.example.test"
    assert_includes response.body, "keine Live-Prüfung"
  end

  test "unknown empty and failed queries remain distinguishable" do
    ENV["PUPPETDB_ENABLED"] = "true"
    get root_path
    assert_select ".puppetdb-host-count", text: "–"
    get certificate_path(@record)
    assert_includes response.body, "noch keine erfolgreiche PuppetDB-Abfrage"
    @record.update!(puppetdb_checked_at: Time.current)
    get root_path
    assert_select ".puppetdb-host-count a", text: "0"
    get certificate_path(@record)
    assert_includes response.body, "auf keinem Host gemeldet"
    @record.update!(puppetdb_hosts: ["cached.example.test"], puppetdb_error_at: Time.current)
    get root_path
    assert_select ".puppetdb-host-count a", text: "1"
    assert_includes response.body, "Abfrage fehlgeschlagen"
    get certificate_path(@record)
    assert_select "#puppetdb-hosts li", text: "cached.example.test"
    assert_includes response.body, "können veraltet sein"
  end

  test "archived records show escaped hostnames while foreign certificate details stay inaccessible" do
    ENV["PUPPETDB_ENABLED"] = "true"
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
    ENV["PUPPETDB_ENABLED"] = "true"
    ENV["PUPPETDB_FINGERPRINT_ALGORITHM"] = "sha1"
    @record.update!(sha1_fingerprint: nil)
    get root_path
    assert_select ".puppetdb-host-count a", count: 0
    assert_includes response.body, "Fingerprint fehlt"
    get certificate_path(@record)
    assert_includes response.body, "Fingerprint für den gewählten PuppetDB-Abgleich fehlt"
    assert_includes response.body, "noch keine erfolgreiche PuppetDB-Abfrage"
  end
end
