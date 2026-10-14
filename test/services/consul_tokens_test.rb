# frozen_string_literal: true

require "test_helper"
require "socket"

class ConsulTokensTest < ActiveSupport::TestCase
  setup do
    @previous = ENV.to_h.slice("CCI_CONSUL_TOKENS", "CONSUL_TOKEN")
    ENV["CCI_CONSUL_TOKENS"] = '{"zone_a":"area-a-secret","zone_b":"area-b-secret"}'
    ENV["CONSUL_TOKEN"] = "global-secret"
  end

  teardown do
    %w[CCI_CONSUL_TOKENS CONSUL_TOKEN].each { |name| ENV[name] = @previous[name] }
  end

  test "area overrides fallback and absent entries retain global or anonymous behavior" do
    assert_equal "area-a-secret", ConsulTokens.resolve("zone_a")
    assert_equal "area-b-secret", ConsulTokens.resolve("zone_b", fallback: "explicit")
    ENV["CCI_CONSUL_TOKENS"] = "{}"
    assert_equal "global-secret", ConsulTokens.resolve("zone_a")
    assert_equal "explicit", ConsulTokens.resolve("zone_a", fallback: "explicit")
    ENV.delete("CONSUL_TOKEN")
    assert_equal "", ConsulTokens.resolve("zone_a")
  end

  test "malformed configurations reject values without exposing secrets" do
    ["secret-json", "[]", "null", '{"unknown":"secret"}', '{"zone_a":1}', '{"zone_a":null}',
      '{"zone_a":{}}', '{"zone_a":""}', '{"zone_a":"a secret"}', '{"zone_a":"a\\nsecret"}'].each do |value|
      error = assert_raises(ArgumentError) do
        ConsulTokens.mapping({ "CCI_CONSUL_TOKENS" => value }, areas: %w[zone_a zone_b])
      end
      assert_not_includes error.message, "secret"
    end
    assert_raises(ArgumentError) { ConsulTokens.resolve("unknown") }
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
      { message: "area-a-secret global-secret", CCI_CONSUL_TOKENS: ENV.fetch("CCI_CONSUL_TOKENS", nil) })
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
