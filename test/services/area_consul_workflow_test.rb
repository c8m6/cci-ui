# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/read_certificate"

class AreaConsulWorkflowTest < ActiveSupport::TestCase
  setup do
    settings["areas"]["zone_a"]["consul"] = { "token" => "synthetic-area-a" }
    settings["areas"]["zone_b"]["consul"] = { "token" => "synthetic-area-b" }
    @http_new = Net::HTTP.method(:new)
    @requests = []
    original = @http_new
    requests = @requests
    Net::HTTP.define_singleton_method(:new) do |*arguments|
      http = original.call(*arguments)
      send_request = http.method(:request)
      http.define_singleton_method(:request) do |request, *arguments, &block|
        requests << [request.path, request["X-Consul-Token"], request.body] if http.started?
        send_request.call(request, *arguments, &block)
      end
      http
    end
  end

  teardown do
    Net::HTTP.define_singleton_method(:new, @http_new)
  end

  test "writers clients material loads and metadata mutations use only their area credential" do
    cert, key = issue
    writer = CciWriter.new(prefix: ConsulStore.namespace)
    prepared = writer.prepare(area: "zone_a", certid: "writer", cert: cert, key: key, tags: [], client: "test", actor: "test")
    writer.commit(prepared)
    @requests.each { |_path, token, _body| assert_equal "synthetic-area-a", token }
    CatalogIndexer.new.consul
    record = Certificate.find_by!(area: "zone_a", certid: "writer")
    @requests.clear
    assert CertificateMaterial.load(record, private_key: true).fetch(:certificate).check_private_key(key)
    CciClient.new(url: settings["consul"]["url"], prefix: ConsulStore.namespace).read_certificate(area: "zone_a", certid: "writer")
    ConsulStore.set_status("zone_a", record.source_id, status: "norollout", actor: "test",
      expected_certid_index: ConsulStore.status_snapshot(record).fetch(:index))
    @requests.each { |_path, token, _body| assert_equal "synthetic-area-a", token }
    @requests.clear
    store(issue.first, area: "zone_b")
    @requests.each do |path, token, body|
      keys = path.start_with?("/v1/txn") ? JSON.parse(body).map { |operation| operation.fetch("KV").fetch("Key") } : [path]
      expected = keys.first.include?("/zone_a/") ? "synthetic-area-a" : "synthetic-area-b"
      assert_equal expected, token
    end
  end

  test "health probes only public metadata with the corresponding area token" do
    assert_empty ApplicationHealth.check
    assert_equal 2, @requests.size
    @requests.each do |path, token, _body|
      assert_match %r{/certids/\?keys&consistent\z}, path
      area = path.include?("/zone_a/") ? "a" : "b"
      assert_equal "synthetic-area-#{area}", token
    end
  end

  test "every Consul workflow resolves the area cluster prefix CA and token together" do
    settings["areas"]["zone_a"]["consul"].merge!("url" => "https://consul-a.example.test:8501", "prefix" => "cluster-a",
      "ca_file" => "/synthetic/ca-a.pem")
    settings["areas"]["zone_b"]["consul"].merge!("url" => "https://consul-b.example.test:8502", "prefix" => "cluster-b",
      "ca_file" => "/synthetic/ca-b.pem")
    captured = []
    original = @http_new
    Net::HTTP.define_singleton_method(:new) do |host, port, *arguments|
      http = original.call(host, port, *arguments)
      http.define_singleton_method(:request) do |request|
        captured << { host: host, port: port, ca: ca_file, path: request.path, token: request["X-Consul-Token"], body: request.body }
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.instance_variable_set(:@read, true)
        response.body = request.path == "/v1/txn" ? JSON.generate("Results" => []) : "[]"
        response
      end
      http
    end
    cert, = issue
    %w[zone_a zone_b].each do |area|
      ConsulStore.save(area: area, cert: cert, key: nil, tags: [], certid: "routing", actor: "test", client: "test")
      assert_raises(CciClient::Error) { CertificateReadExample.read(area: area, certid: "routing") }
    end
    CatalogIndexer.new.consul
    assert_empty ApplicationHealth.check
    captured.each do |event|
      suffix = event.fetch(:host).include?("consul-a") ? "a" : "b"
      assert_equal suffix == "a" ? 8501 : 8502, event.fetch(:port)
      assert_equal "/synthetic/ca-#{suffix}.pem", event.fetch(:ca)
      assert_equal "synthetic-area-#{suffix}", event.fetch(:token)
      if event.fetch(:path) == "/v1/txn"
        assert(JSON.parse(event.fetch(:body)).all? do |op|
          op.fetch("KV").fetch("Key").start_with?("cluster-#{suffix}/zone_#{suffix}/")
        end)
      else
        assert event.fetch(:path).start_with?("/v1/kv/cluster-#{suffix}/zone_#{suffix}/")
      end
    end
    assert_equal %w[consul-a.example.test consul-b.example.test], captured.pluck(:host).uniq.sort
  end

  test "ACL failure in one area preserves its rows but still refreshes another area" do
    previous = store(issue.first)
    new_cert, = issue(name: "new.example.test")
    CciWriter.new(prefix: ConsulStore.namespace).save(area: "zone_b", certid: "new", cert: new_cert, key: nil,
      tags: [], client: "test", actor: "test")
    original = ConsulStore.method(:client)
    ConsulStore.define_singleton_method(:client) do |area = nil|
      connection = original.call(area)
      connection.define_singleton_method(:all) { |_| raise ConsulConnection::AclError, "ACL denied for area zone_a" } if area == "zone_a"
      connection
    end
    assert_raises(ConsulConnection::AclError) { CatalogIndexer.new.consul }
    assert Certificate.exists?(previous.id)
    assert Certificate.exists?(area: "zone_b", certid: "new")
    assert_raises(ConsulConnection::AclError) { ConsulStore.client("zone_a").all("#{ConsulStore.prefix("zone_a")}/certs/") }
  ensure
    ConsulStore.define_singleton_method(:client, original) if original
  end
end
