require "test_helper"
require "open3"
require_relative "../../examples/add_certificate"
require_relative "../../examples/read_certificate"

class RubyIntegrationExamplesTest < ActiveSupport::TestCase
  def publish(cert, key: nil)
    CertificateExample.add(area: "zone_a", lookup: "external", cert: cert, key: key,
      client: "external-ruby", actor: "svc-import")
  end

  def read(**options)
    CertificateReadExample.read(area: "zone_a", lookup: "external", **options)
  end

  test "renewal rollback and explicit pinning follow the lookup with matching keys" do
    first_cert, first_key = issue
    first = publish(first_cert, key: first_key)
    path = "#{ConsulStore.prefix('zone_a')}/lookups/external"
    entry = JSON.parse(ConsulStore.client.get(path).fetch(:value))
    assert_equal Digest::SHA256.hexdigest("#{entry.fetch('entry_id')}:#{Digest::SHA256.hexdigest(first_cert.to_der)}"), first
    cached = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    assert_equal first_cert.to_pem, cached.fetch(area: "zone_a", lookup: "external")

    second_cert, second_key = issue(serial: 2)
    second = publish(second_cert, key: second_key)
    renewed_entry = JSON.parse(ConsulStore.client.get(path).fetch(:value))
    assert_equal entry.fetch("entry_id"), renewed_entry.fetch("entry_id")
    assert_equal second, renewed_entry.fetch("active_version")
    current = read(private_key: true)
    assert_equal second, current.fetch("metadata").fetch("version_id")
    assert_equal second_cert.to_pem, current.fetch("certificate")
    assert second_cert.check_private_key(OpenSSL::PKey.read(current.fetch("private_key")))
    assert first_cert.check_private_key(OpenSSL::PKey.read(cached.fetch(area: "zone_a", lookup: "external", field: "private_key")))
    assert_equal first, cached.fetch(area: "zone_a", lookup: "external", field: "metadata").fetch("version_id")
    pinned = read(version: first, private_key: true)
    assert_equal first_cert.to_pem, pinned.fetch("certificate")
    assert first_cert.check_private_key(OpenSSL::PKey.read(pinned.fetch("private_key")))

    before_duplicate = ConsulStore.client.all("#{ConsulStore.namespace}/")
    assert_raises(ConsulConnection::Conflict) { publish(first_cert, key: first_key) }
    assert_equal before_duplicate, ConsulStore.client.all("#{ConsulStore.namespace}/")
    ConsulStore.activate("zone_a", first, actor: "svc-rollback")
    assert_equal first, read.fetch("metadata").fetch("version_id")
    assert_equal second, read(version: second).fetch("metadata").fetch("version_id")
    assert_equal 2, ConsulStore.client.all("#{ConsulStore.prefix('zone_a')}/versions/").size

    output, error, status = Open3.capture3(RbConfig.ruby, Rails.root.join("examples/read_certificate.rb").to_s,
      "zone_a", "external")
    assert status.success?, error
    cli = JSON.parse(output)
    assert_equal first, cli.fetch("metadata").fetch("version_id")
    assert_equal first_cert.to_pem, cli.fetch("chain")
    assert_not cli.key?("private_key")
  end

  test "imports retain status archive metadata and additional lookup fields" do
    first = publish(issue.first)
    path = "#{ConsulStore.prefix('zone_a')}/lookups/external"
    snapshot = ConsulStore.client.get(path)
    state = JSON.parse(snapshot.fetch(:value)).merge("status" => "delete", "archived" => true,
      "archived_at" => Time.now.utc.iso8601, "archived_by" => "svc-archive", "custom" => "retained")
    ConsulStore.client.transaction([ConsulConnection.set(path, state, index: snapshot.fetch(:index))])
    second = publish(issue(serial: 2).first)
    assert_equal state.merge("active_version" => second), JSON.parse(ConsulStore.client.get(path).fetch(:value))
    assert_equal "delete", read.fetch("metadata").fetch("status")
    assert_equal "delete", read(version: first).fetch("metadata").fetch("status")
  end

  test "a concurrent lookup update rejects the entire example import" do
    first = publish(issue.first)
    connection = ConsulStore.client
    path = "#{ConsulStore.prefix('zone_a')}/lookups/external"
    original_get = connection.method(:get)
    connection.define_singleton_method(:get) do |key|
      snapshot = original_get.call(key)
      if key == path
        entry = JSON.parse(snapshot.fetch(:value)).merge("status" => "norollout")
        transaction([ConsulConnection.set(path, entry, index: snapshot.fetch(:index))])
      end
      snapshot
    end
    cert, key = issue(serial: 2)
    assert_raises(ConsulConnection::Conflict) do
      CertificateExample.add(area: "zone_a", lookup: "external", cert: cert, key: key,
        client: "external-ruby", actor: "svc-import", connection: connection)
    end
    assert_equal first, read.fetch("metadata").fetch("version_id")
    assert_equal "norollout", read.fetch("metadata").fetch("status")
    assert_equal 1, ConsulStore.client.all("#{ConsulStore.prefix('zone_a')}/versions/").size
    assert_empty ConsulStore.client.all("#{ConsulStore.prefix('zone_a')}/private-keys/")
    assert_equal 1, ConsulStore.client.all("#{ConsulStore.namespace}/events/").size
  end
end
