# Run only in the disposable screenshot stack, never against a real inventory.
require "fileutils"
abort "Screenshot namespace required" unless ConsulStore.namespace == "cci-screenshots/v1"
abort "Screenshot database required" unless ActiveRecord::Base.connection_db_config.database == "screenshots"
abort "Use a fresh screenshot stack for each capture" if Certificate.exists?

def issue(name, serial:, days:, issuer: nil, issuer_key: nil, ca: false)
  key = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = serial
  cert.subject = OpenSSL::X509::Name.parse("/O=Example Demo/CN=#{name}")
  cert.issuer = issuer ? issuer.subject : cert.subject
  cert.public_key = key.public_key
  cert.not_before = 60.days.ago
  cert.not_after = days.days.from_now
  factory = OpenSSL::X509::ExtensionFactory.new
  factory.subject_certificate = cert
  factory.issuer_certificate = issuer || cert
  cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
  cert.add_extension(factory.create_extension("subjectAltName", "DNS:#{name}")) unless ca
  cert.sign(issuer_key || key, OpenSSL::Digest::SHA256.new)
  [cert, key]
end

actor = "demo.operator@example.test"
root, root_key = issue("Example Demo CA", serial: 1, days: 730, ca: true)
legacy, = issue("monitor.example.test", serial: 2, days: 95, issuer: root, issuer_key: root_key)
FileUtils.mkdir_p("/tmp/cci-screenshot-legacy")
legacy_root = LegacyStore.root(area: "zone_a")
File.write(legacy_root.join("demo-ca.pem"), root.to_pem)
File.write(legacy_root.join("monitor.pem"), legacy.to_pem)

AreaConfiguration.ids.each do |area|
  ConsulStore.save(area: area, certid: "demo-root", cert: root, key: nil, tags: ["CA"], actor: actor, client: "cci-ui")
end
issued = {}
[
  ["portal.example.test", "zone_a", "portal.production", -5, "Production"],
  ["portal.example.test", "zone_a", "portal.production", 180, "Production"],
  ["api.example.test", "zone_a", "api.production", 18, "Production"],
  ["gateway.example.test", "zone_b", "gateway.production", -7, "Renewal"],
  ["staging.example.test", "zone_b", "portal.staging", 90, "Staging"],
  ["retired.example.test", "zone_b", "retired.service", 60, "Retired"]
].each_with_index do |(name, area, certid, days, tag), index|
  cert, key = issue(name, serial: 10 + index, days: days, issuer: root, issuer_key: root_key)
  id = ConsulStore.save(area: area, cert: cert, key: key, tags: [tag],
    certid: certid, actor: actor, client: "cci-ui")
  issued[certid] = [cert, id, area]
end
CatalogIndexer.new.filesystem
CatalogIndexer.refresh_consul

# Exercise real export auditing and the normal status/archive services.
portal = Certificate.find_by!(source_id: issued.fetch("portal.production")[1])
identity = Identity.new(name: actor, roles: %w[zone_a_writer zone_a_key_exporter])
CertificateExport.call([portal], identity: identity, format: "pem", include_key: false,
  include_chain: true, password: "", source_password: "")

[["gateway.production", "delete"], ["portal.staging", "norollout"]].each do |certid, status|
  _, id, area = issued.fetch(certid)
  ConsulStore.set_status(area, id, status: status, actor: actor,
    expected_certid_index: ConsulStore.certid_snapshot(area, certid).fetch(:index))
end
retired = Certificate.find_by!(source_id: issued.fetch("retired.service")[1])
ConsulStore.archive(retired, actor: actor,
  expected_certid_index: ConsulStore.status_snapshot(retired).fetch(:index))
CatalogIndexer.refresh_consul

# Feed a synthetic PuppetDB response through the production fingerprint mapper.
host_certids = {
  "web01.example.test" => %w[portal.production],
  "web02.example.test" => %w[portal.production],
  "proxy01.example.test" => %w[portal.production api.production],
  "api01.example.test" => %w[api.production],
  "gateway01.example.test" => %w[gateway.production],
  "stage01.example.test" => %w[portal.staging],
  "old01.example.test" => %w[retired.service]
}
rows = host_certids.map do |host, certids|
  fingerprints = certids.map { |certid| Certificates::Codec.fingerprint(issued.fetch(certid).first) }
  fingerprints << Certificates::Codec.fingerprint(root) if host.start_with?("web", "proxy")
  fingerprints << Certificates::Codec.fingerprint(legacy) if host.start_with?("web")
  { "certname" => host, "facts" => { "certificates" => fingerprints.map { |fp| { "fingerprint" => fp } } } }
end
connection = Object.new
connection.define_singleton_method(:inventory) { |_query| rows }
PuppetdbInventory.refresh(connection: connection)
abort "Demo host mapping failed" unless portal.reload.puppetdb_hosts.size == 3
puts "Synthetic screenshot inventory ready: #{Certificate.count} certificates, #{rows.size} hosts."
