# frozen_string_literal: true

require "test_helper"

class PuppetdbInventoryTest < ActiveSupport::TestCase
  setup do
    @environment = { "PUPPETDB_ENABLED" => "true", "PUPPETDB_FACT_NAME" => "certificates" }
    @record = store(issue.first)
    @configuration = PuppetdbConfiguration.new(@environment)
  end

  def row(host, value)
    { "certname" => host, "facts" => { "certificates" => value, "unrelated" => "ignored" } }
  end

  def refresh(rows, environment: @environment)
    connection = Object.new
    connection.define_singleton_method(:inventory) { |_query| rows }
    PuppetdbInventory.refresh(environment: environment, connection: connection)
  end

  test "disabled feature never queries PuppetDB or changes cached data" do
    @record.update!(puppetdb_hosts: ["old.example.test"], puppetdb_checked_at: 1.hour.ago)
    connection = Object.new
    connection.define_singleton_method(:inventory) { |_| raise "Unexpected PuppetDB request" }
    PuppetdbInventory.refresh(environment: { "PUPPETDB_ENABLED" => "false", "PUPPETDB_URL" => "invalid" },
      connection: connection)
    assert_equal ["old.example.test"], @record.reload.puppetdb_hosts
    assert_not PuppetdbConfiguration.enabled?({})
    assert PuppetdbConfiguration.enabled?({ "PUPPETDB_ENABLED" => "1" })
    assert_raises(PuppetdbConnection::Error) { PuppetdbConfiguration.enabled?({ "PUPPETDB_ENABLED" => "typo" }) }
  end

  test "default query uses the configured anonymous fact name and custom query is passed unchanged" do
    assert_equal 'inventory[certname,facts]{ certname in fact_contents[certname]{ name = "certificates" } }',
      @configuration.query
    environment = @environment.merge("PUPPETDB_FACT_NAME" => "example_certificates",
      "PUPPETDB_QUERY" => 'inventory[certname,facts] { certname = "web.example.test" }')
    connection = Object.new
    received = []
    connection.define_singleton_method(:inventory) do |query|
      received << query
      []
    end
    PuppetdbInventory.refresh(environment: environment, connection: connection)
    assert_equal [environment.fetch("PUPPETDB_QUERY")], received
    generated = PuppetdbConfiguration.new(environment.except("PUPPETDB_QUERY"))
    assert_includes generated.query, 'name = "example_certificates"'
  end

  test "SHA-1 matching is configurable and does not change the SHA-256 catalog identity" do
    cert = OpenSSL::X509::Certificate.new(ConsulStore.get(@record.area, @record.source_id).fetch("pem"))
    assert_equal Digest::SHA1.hexdigest(cert.to_der), @record.sha1_fingerprint
    original_identity = @record.fingerprint
    other = store(issue(serial: 2).first)
    environment = @environment.merge("PUPPETDB_FINGERPRINT_ALGORITHM" => "SHA-1")
    grouped = @record.sha1_fingerprint.upcase.scan(/../).join(":")
    refresh([row("sha1.example.test", [{ "fingerprint" => "SHA1 Fingerprint=#{grouped}" }])], environment: environment)
    assert_equal ["sha1.example.test"], @record.reload.puppetdb_hosts
    assert_equal original_identity, @record.fingerprint
    assert_empty other.reload.puppetdb_hosts
    assert_raises(PuppetdbConnection::Error) do
      refresh([row("wrong.example.test", @record.fingerprint)], environment: environment)
    end
    assert_equal ["sha1.example.test"], @record.reload.puppetdb_hosts
    assert_raises(PuppetdbConnection::Error) do
      PuppetdbConfiguration.new("PUPPETDB_FINGERPRINT_ALGORITHM" => "md5")
    end
  end

  test "SHA-1 sync retains earlier observations for records whose source has not been reindexed" do
    refresh([row("known.example.test", @record.fingerprint)])
    @record.reload.update!(sha1_fingerprint: nil)
    checked_at = @record.puppetdb_checked_at
    refresh([], environment: @environment.merge("PUPPETDB_FINGERPRINT_ALGORITHM" => "sha1"))
    assert_equal ["known.example.test"], @record.reload.puppetdb_hosts
    assert_equal checked_at, @record.puppetdb_checked_at
    CatalogIndexer.refresh_consul
    assert @record.reload.sha1_fingerprint
    refresh([], environment: @environment.merge("PUPPETDB_FINGERPRINT_ALGORITHM" => "sha1"))
    assert_empty @record.reload.puppetdb_hosts
  end

  test "fingerprints map exact certificates to sorted unique hosts across copies sources and archived versions" do
    duplicate = @record.dup
    duplicate.assign_attributes(source: "filesystem", source_id: "copy.pem#0", certid: nil,
      archived: false, rollout_status: "active")
    duplicate.save!
    other = store(issue(serial: 2).first)
    @record.update!(archived: true, rollout_status: "delete")
    grouped = @record.fingerprint.upcase.scan(/../).join(":")
    refresh([
      row("z.example.test",
        [{ "fingerprint" => grouped, "subject" => "ignored", "file" => "/etc/ssl/cert.pem" },
          { "fingerprint" => @record.fingerprint }]),
      row("a.example.test", { "/etc/ssl/cert.pem" => { "fingerprint" => "SHA256 Fingerprint=#{grouped}" } }),
      row("z.example.test", @record.fingerprint),
      row("other.example.test", ["a" * 64])
    ])
    assert_equal %w[a.example.test z.example.test], @record.reload.puppetdb_hosts
    assert_equal @record.puppetdb_hosts, duplicate.reload.puppetdb_hosts
    assert_not duplicate.archived
    assert_equal "active", duplicate.rollout_status
    assert_empty other.reload.puppetdb_hosts
    assert_equal @record.puppetdb_checked_at, other.puppetdb_checked_at
    assert_nil @record.puppetdb_error_at
    assert_not @record.active
  end

  test "successful complete refresh replaces previous hosts including an empty result" do
    refresh([row("old.example.test", @record.fingerprint)])
    refresh([row("new.example.test", @record.fingerprint)])
    assert_equal ["new.example.test"], @record.reload.puppetdb_hosts
    assert_no_difference "Certificate.count" do
      refresh([])
    end
    assert_empty @record.reload.puppetdb_hosts
    assert @record.puppetdb_checked_at
  end

  test "malformed partial facts and mismatched fingerprint algorithms preserve last successful associations" do
    refresh([row("old.example.test", @record.fingerprint)])
    checked_at = @record.reload.puppetdb_checked_at
    invalid_rows = [nil, {}, [{ "certname" => "host.example.test", "facts" => {} }],
      [row("host.example.test", nil)], [row("host.example.test", [{ "fingerprint" => "a" * 40 }])],
      [row("host.example.test", [{ "subject" => "CN=not-an-identity" }])],
      [row("host.example.test", [{ "fingerprint" => nil }])], [row("invalid\nhost", [])]]
    invalid_rows.each do |rows|
      assert_raises(PuppetdbConnection::Error) { refresh(rows) }
      assert_equal ["old.example.test"], @record.reload.puppetdb_hosts
      assert_equal checked_at, @record.puppetdb_checked_at
      assert @record.puppetdb_refresh_failed?
    end
    assert_raises(PuppetdbConnection::Error) do
      refresh([row("new.example.test", @record.fingerprint), row("bad.example.test", "invalid")])
    end
    assert_equal ["old.example.test"], @record.reload.puppetdb_hosts
    refresh([row("new.example.test", @record.fingerprint)])
    assert_nil @record.reload.puppetdb_error_at
  end

  test "network errors retain host cache and certificate statuses" do
    refresh([row("old.example.test", @record.fingerprint)])
    connection = Object.new
    connection.define_singleton_method(:inventory) { |_| raise PuppetdbConnection::Error, "Unavailable" }
    assert_raises(PuppetdbConnection::Error) { PuppetdbInventory.refresh(environment: @environment, connection: connection) }
    assert_equal ["old.example.test"], @record.reload.puppetdb_hosts
    assert_equal "active", @record.rollout_status
    assert_not @record.archived
  end

  test "fact name and fingerprint field can be configured without examining unrelated facts" do
    configuration = PuppetdbConfiguration.new("PUPPETDB_FACT_NAME" => "example_inventory",
      "PUPPETDB_FINGERPRINT_FIELD" => "sha256")
    rows = [{ "certname" => "web.example.test",
              "facts" => { "example_inventory" => { "cert.pem" => { "sha256" => @record.fingerprint } },
                           "certificates" => nil } }]
    assert_equal ["web.example.test"],
      PuppetdbInventory.new(configuration).hosts_by_fingerprint(rows).fetch(@record.fingerprint).to_a
  end

  test "scheduled indexing runs PuppetDB even after a source failure and refresh_consul skips it" do
    called = []
    original = CatalogIndexer.method(:new)
    indexer = CatalogIndexer.new
    indexer.define_singleton_method(:filesystem) do
      called << :filesystem
      raise Certificates::Error, "Unavailable"
    end
    indexer.define_singleton_method(:consul) { called << :consul }
    indexer.define_singleton_method(:puppetdb) { called << :puppetdb }
    CatalogIndexer.define_singleton_method(:new) { indexer }
    assert_raises(Certificates::Error) { CatalogIndexer.run }
    assert_equal %i[filesystem consul puppetdb], called
    called.clear
    CatalogIndexer.refresh_consul
    assert_equal [:consul], called
  ensure
    CatalogIndexer.define_singleton_method(:new, original) if original
  end
end
