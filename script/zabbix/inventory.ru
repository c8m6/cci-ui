# frozen_string_literal: true

require "json"

# Synthetic public metadata served only on the disposable validation network.
module ZabbixFixture
  def self.payload(mode)
    now = Time.now.to_i
    rows = [[1, "manual", 45], [2, "manual", 20], [3, "manual", 5],
      [4, "acme", 10], [5, "acme", 5], [6, "puppet", 1], [7, "puppet", 90]]
    certificates = rows.map do |id, renewal, days|
      { id: id, common_name: "#{renewal}-#{id}.example.test", issuer: "/CN=Synthetic Test CA", serial_number: id.to_s,
        valid_from: now - 86_400, valid_until: now + (days * 86_400), renewal: renewal }
    end
    certificates.each { |certificate| certificate[:valid_until] = now + (180 * 86_400) } if mode == "renewed"
    certificates = [] if mode == "empty"
    version = mode == "schema" ? 2 : 1
    now -= 10_000 if mode == "stale"
    JSON.generate(version: version, generated_at: now, certificates: certificates)
  end
end

run lambda { |env|
  next [401, { "content-type" => "text/plain" }, [""]] unless env["HTTP_AUTHORIZATION"] == "Bearer synthetic-zabbix-test-token"

  mode = File.exist?("/tmp/mode") ? File.read("/tmp/mode").strip : "valid"
  next [503, { "content-type" => "text/plain" }, [""]] if mode == "unavailable"

  body = mode == "invalid" ? "invalid JSON" : ZabbixFixture.payload(mode)
  [200, { "content-type" => "application/json" }, [body]]
}
