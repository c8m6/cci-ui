# frozen_string_literal: true

require "test_helper"
require "open3"
require_relative "../../examples/add_certificate"
require_relative "../../examples/read_certificate"

class RubyIntegrationExamplesTest < ActiveSupport::TestCase
  def publish(cert, key: nil, **)
    CertificateExample.add(area: "zone_a", certid: "external", cert: cert, key: key, **)
  end

  def read(**)
    CertificateReadExample.read(area: "zone_a", certid: "external", **)
  end

  def counting_connection
    connection = ConsulStore.client
    calls = []
    original = connection.method(:request)
    connection.define_singleton_method(:request) do |method, path, **options|
      calls << [method, path]
      original.call(method, path, **options)
    end
    [connection, calls]
  end

  test "writes and reads require only two requests including the private key" do
    cert, key = issue
    connection, calls = counting_connection
    assert_equal 1, publish(cert, key: key, connection: connection)
    assert_equal 2, calls.size
    assert_match %r{/certids/external}, calls.first.last
    assert_equal ["put", "/v1/txn"], calls.last
    calls.clear
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      connection: connection, keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    assert_equal cert.to_pem, reader.read_certificate(area: "zone_a", certid: "external")
    assert cert.check_private_key(OpenSSL::PKey.read(reader.read_certificate(area: "zone_a", certid: "external",
      field: "private_key")))
    metadata = reader.read_certificate(area: "zone_a", certid: "external", field: "metadata")
    assert_equal "puppet", metadata.fetch("client")
    assert Time.iso8601(metadata.fetch("created_at"))
    assert_equal 1, metadata.fetch("version")
    assert_equal 2, calls.size
    assert_empty AuditEvent.all
    assert_equal 3, ConsulStore.client.all("#{ConsulStore.namespace}/").size
  end

  test "renewal pinning rollback and monotonically increasing versions" do
    first_cert, first_key = issue
    first = publish(first_cert, key: first_key)
    cached = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    assert_equal first_cert.to_pem, cached.read_certificate(area: "zone_a", certid: "external")
    second_cert, second_key = issue(serial: 2)
    second = publish(second_cert, key: second_key)
    assert_equal [1, 2], [first, second]
    assert_equal second_cert.to_pem, read.fetch("certificate")
    assert first_cert.check_private_key(OpenSSL::PKey.read(cached.read_certificate(area: "zone_a", certid: "external",
      field: "private_key")))
    assert_equal first_cert.to_pem, read(version: 1).fetch("certificate")
    ConsulStore.activate("zone_a", "external/1", actor: "rollback-user")
    assert_equal 1, read.fetch("metadata").fetch("version")
    assert_equal 3, publish(first_cert)
    assert_equal 3, read.fetch("metadata").fetch("version")
    output, error, status = Open3.capture3(RbConfig.ruby, Rails.root.join("examples/read_certificate.rb").to_s,
      "zone_a", "external", "2")
    assert status.success?, error
    assert_equal 2, JSON.parse(output).fetch("metadata").fetch("version")
  end

  test "flat area paths isolate identical certids and encrypted keys" do
    certificates = {}
    %w[zone_a zone_b].each_with_index do |area, index|
      cert, key = issue(serial: index + 1)
      certificates[area] = cert
      assert_equal 1, CertificateExample.add(area: area, certid: "shared", cert: cert, key: key)
      base = "#{ConsulStore.namespace}/#{area}"
      entries = ConsulStore.client.all("#{base}/").to_h { |item| [item.fetch(:key), JSON.parse(item.fetch(:value))] }
      assert_equal ["#{base}/certids/shared", "#{base}/certs/shared/1", "#{base}/keys/shared/1"].sort, entries.keys.sort
      assert_equal cert.to_pem, entries.fetch("#{base}/certs/shared/1").fetch("pem")
      assert_equal %w[data iv tag version], entries.fetch("#{base}/keys/shared/1").keys.sort
      assert_not_includes entries.fetch("#{base}/keys/shared/1").to_json, "PRIVATE KEY"
    end
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/areas/")
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      keys: { "zone_a" => ENV.fetch("ZONE_A_KEY"), "zone_b" => ENV.fetch("ZONE_B_KEY") })
    certificates.each do |area, cert|
      assert_equal cert.to_pem, reader.read_certificate(area: area, certid: "shared")
      assert cert.check_private_key(OpenSSL::PKey.read(reader.read_certificate(area: area, certid: "shared",
        field: "private_key")))
    end
    CatalogIndexer.refresh_consul
    assert_equal 2, Certificate.where(certid: "shared", active: true).count
  end

  test "concurrent creation uses index zero and rejects the losing transaction" do
    writer = CciWriter.new(prefix: ConsulStore.namespace)
    cert, key = issue
    first = writer.prepare(area: "zone_a", certid: "new", cert: cert, key: key)
    second = writer.prepare(area: "zone_a", certid: "new", cert: issue(serial: 2).first)
    assert(first.fetch(:operations).all? do |operation|
      operation.fetch("Verb") == "cas" && operation.fetch("Index").zero?
    end)
    writer.commit(first)
    assert_raises(ConsulConnection::Conflict) { writer.commit(second) }
    assert_equal cert.to_pem, ConsulStore.get("zone_a", "new/1").fetch("pem")
    assert_equal 3, ConsulStore.client.all("#{ConsulStore.namespace}/").size
  end

  test "packaged Puppet libraries match application libraries" do
    %w[cci_client.rb cci_writer.rb consul_connection.rb area_secrets.rb].each do |file|
      assert_equal File.read(Rails.root.join("lib", file)),
        File.read(Rails.root.join("integrations/puppet/cci/lib", file)), file
    end
  end

  test "external renewals preserve archive status and unknown fields" do
    publish(issue.first)
    path = "#{ConsulStore.prefix("zone_a")}/certids/external"
    snapshot = ConsulStore.client.get(path)
    state = JSON.parse(snapshot.fetch(:value)).merge("status" => "delete", "archived" => true,
      "archived_at" => Time.now.utc.iso8601, "archived_by" => "writer", "custom" => "retained")
    ConsulStore.client.transaction([ConsulConnection.set(path, state, index: snapshot.fetch(:index))])
    assert_equal 2, publish(issue(serial: 2).first)
    updated = JSON.parse(ConsulStore.client.get(path).fetch(:value))
    assert_equal state.except("active_version", "latest_version", "updated_at"),
      updated.except("active_version", "latest_version", "updated_at")
    assert_equal "delete", read.fetch("metadata").fetch("status")
  end

  test "concurrent metadata updates reject all material writes" do
    publish(issue.first)
    connection = ConsulStore.client
    path = "#{ConsulStore.prefix("zone_a")}/certids/external"
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
    assert_raises(ConsulConnection::Conflict) { publish(cert, key: key, connection: connection) }
    assert_equal 1, read.fetch("metadata").fetch("version")
    assert_equal "norollout", read.fetch("metadata").fetch("status")
    assert_equal 1, ConsulStore.client.all("#{ConsulStore.prefix("zone_a")}/certs/").size
    assert_empty ConsulStore.client.all("#{ConsulStore.prefix("zone_a")}/keys/")
  end

  test "client builds chain from independent public certificates and caches candidates" do
    root, root_key = issue(name: "Root", ca: true)
    intermediate, intermediate_key = issue(name: "Intermediate", issuer: root, issuer_key: root_key, ca: true)
    leaf, = issue(issuer: intermediate, issuer_key: intermediate_key)
    publish(leaf)
    [root, intermediate].each_with_index do |cert, index|
      CertificateExample.add(area: "zone_a", certid: "ca-#{index}", cert: cert)
    end
    connection, calls = counting_connection
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace, connection: connection)
    assert_equal leaf.to_pem, reader.read_certificate(area: "zone_a", certid: "external")
    assert_equal 2, calls.size
    assert_equal [leaf, intermediate, root].map(&:to_pem).join,
      reader.read_certificate(area: "zone_a", certid: "external", field: "chain")
    assert_equal 3, calls.size
    reader.read_certificate(area: "zone_a", certid: "external", field: "chain")
    assert_equal 3, calls.size
    ConsulStore.client.all("#{ConsulStore.prefix("zone_a")}/certs/").each do |item|
      assert_not JSON.parse(item[:value]).key?("chain")
    end
  end
  test "key-enabled clients can read a certificate without a private key in two requests" do
    cert, = issue
    publish(cert)
    connection, calls = counting_connection
    reader = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace,
      connection: connection, keys: { "zone_a" => ENV.fetch("ZONE_A_KEY") })
    assert_equal cert.to_pem, reader.read_certificate(area: "zone_a", certid: "external")
    assert_equal 2, calls.size
    assert_raises(CciClient::Error) { reader.read_certificate(area: "zone_a", certid: "external", field: "private_key") }
    assert_equal 2, calls.size
  end
end
