# frozen_string_literal: true

require "test_helper"
require "socket"

class ConsulTokensTest < ActiveSupport::TestCase
  setup do
    settings["areas"]["zone_a"]["consul"] = { "token" => "area-a-secret" }
    settings["areas"]["zone_b"]["consul"] = { "token" => "area-b-secret" }
    settings["consul"]["token"] = "global-secret"
  end

  test "area inherits global settings only when no override is configured" do
    assert_equal "area-a-secret", ConsulTokens.resolve("zone_a")
    assert_equal "area-b-secret", ConsulTokens.resolve("zone_b")
    settings["areas"]["zone_a"].delete("consul")
    assert_equal "global-secret", ConsulTokens.resolve("zone_a")
    assert_raises(KeyError) { ConsulTokens.resolve("unknown") }
  end

  test "scoped transport sends the chosen credential and never retries ACL failures" do
    [200, 403, :filtered, :filtered_missing].each do |status|
      with_response(status) do |url, requests|
        connection = ConsulConnection.new(url: url, area: "zone_a", prefix: "custom")
        if status == 200
          assert_empty connection.all("custom/zone_a/certids/")
        else
          error = assert_raises(ConsulConnection::AclError) { connection.all("custom/zone_a/certids/") }
          assert_includes error.message, "zone_a"
          assert_not_includes error.message, "secret"
        end
        assert_equal ["area-a-secret"], requests
      end
    end
  end

  test "scoped reads and transactions reject foreign and traversing keys before HTTP" do
    connection = ConsulConnection.new(url: "http://127.0.0.1:1", area: "zone_a", prefix: "custom")
    assert_equal "/v1/kv/custom/zone_a/certids/", connection.path("custom/zone_a/certids/")
    assert_equal "/v1/kv/custom/zone_a/", connection.path("custom/zone_a/")
    %w[custom/zone_b/certids/test custom/zone_a/../zone_b/test custom/zone_a_extra/test].each do |key|
      assert_raises(ConsulConnection::Error) { connection.path(key) }
      error = assert_raises(ConsulConnection::Error) { connection.transaction([ConsulConnection.set(key, {})]) }
      assert_includes error.message, "outside the assigned area"
    end
  end

  test "logs redact mapping fields and individual tokens even in exception strings" do
    formatter = ContainerLogFormatter.new
    result = formatter.call("WARN", Time.current, "test",
      { message: "area-a-secret global-secret", token: "area-a-secret" })
    %w[area-a-secret area-b-secret global-secret].each { |secret| assert_not_includes result, secret }
    assert_includes result, "FILTERED"
  end

  private

  def with_response(status)
    socket = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      client = socket.accept
      headers = []
      while (line = client.gets) && line != "\r\n"
        headers << line
      end
      requests << headers.find { |line| line.start_with?("X-Consul-Token:") }.to_s.split(":", 2).last.to_s.strip
      filtered = status.is_a?(Symbol) ? "X-Consul-Results-Filtered-By-ACLs: true\r\n" : ""
      code = { filtered: 200, filtered_missing: 404 }.fetch(status, status)
      client.write("HTTP/1.1 #{code} Test\r\n#{filtered}Content-Length: 2\r\nConnection: close\r\n\r\n[]")
    ensure
      client&.close
    end
    yield "http://127.0.0.1:#{socket.addr[1]}", requests
  ensure
    socket&.close
    thread&.join(2) || thread&.kill
  end
end
