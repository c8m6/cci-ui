#!/usr/bin/env ruby
# Standalone Ruby client; needs only the standard library and ConsulConnection.
require_relative "../lib/consul_connection"
require_relative "../lib/area_secrets"
require "securerandom"
require "digest"
require "time"

module CertificateExample
  # Every writing application supplies its own stable client ID.
  def self.add(area:, lookup:, cert:, client:, actor:, key: nil, chain: [], tags: [],
    prefix: ENV.fetch("CONSUL_PREFIX", "cci/v1"), connection: ConsulConnection.new,
    encryption_key: nil)
    raise ArgumentError, "Invalid area" unless area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    raise ArgumentError, "Invalid lookup" unless lookup.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise ArgumentError, "Invalid client" unless client.is_a?(String) && client.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise ArgumentError, "Invalid actor" unless actor.is_a?(String) && !actor.strip.empty? && actor.length <= 255
    raise ArgumentError, "Certificate and key do not match" if key && !cert.check_private_key(key)

    base = "#{prefix}/areas/#{area}"
    lookup_path = "#{base}/lookups/#{lookup}"
    previous = connection.get(lookup_path)
    entry = previous && JSON.parse(previous.fetch(:value))
    status = entry ? entry.fetch("status", "active") : "active"
    raise ArgumentError, "Invalid rollout status" unless %w[active norollout delete].include?(status)
    entry_id = entry ? entry.fetch("entry_id") : SecureRandom.uuid
    fingerprint = Digest::SHA256.hexdigest(cert.to_der)
    id = Digest::SHA256.hexdigest("#{entry_id}:#{fingerprint}")
    now = Time.now.utc.iso8601(6)
    version = {
      schema: "1", entry_id: entry_id, lookup: lookup, pem: cert.to_pem,
      chain: JSON.generate(chain.map(&:to_pem)), tags: JSON.generate(tags),
      fingerprint: fingerprint,
      public_key_fingerprint: Digest::SHA256.hexdigest(cert.public_key.public_to_der),
      has_key: key ? "1" : "0", created_at: now, client: client, created_by: actor
    }
    # Keep audit metadata available even after deletion of this version.
    snapshot = {
      common_name: cert.subject.to_a.find { |name, _, _| name == "CN" }&.at(1),
      subject: cert.subject.to_s, issuer: cert.issuer.to_s,
      serial: cert.serial.to_i.to_s(16), fingerprint: fingerprint,
      source: "consul", source_id: id, lookup: lookup, kind: "selected"
    }
    event = {
      action: "import", area: area, id: id, actor: actor, at: now,
      details: { certificates: [snapshot], previous_version: entry && entry["active_version"],
        tags: tags, has_key: !key.nil? }
    }
    operations = [
      ConsulConnection.set(lookup_path, (entry || {}).merge("entry_id" => entry_id, "active_version" => id, "status" => status), index: previous ? previous.fetch(:index) : 0),
      ConsulConnection.set("#{base}/versions/#{id}", version, index: 0),
      ConsulConnection.set("#{prefix}/events/#{SecureRandom.uuid}", event, index: 0)
    ]
    if key
      secret = Base64.strict_decode64(encryption_key || AreaSecrets.fetch(area))
      raise ArgumentError, "Area key must contain 32 bytes" unless secret.bytesize == 32
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = secret
      iv = cipher.random_iv
      cipher.auth_data = "cci:v1:#{area}:#{id}"
      ciphertext = cipher.update(key.private_to_pem) + cipher.final
      envelope = { version: 1, iv: Base64.strict_encode64(iv),
        tag: Base64.strict_encode64(cipher.auth_tag), data: Base64.strict_encode64(ciphertext) }
      operations << ConsulConnection.set("#{base}/private-keys/#{id}", envelope, index: 0)
    end
    # A CAS conflict rejects the entire transaction. Never overwrite on conflict.
    connection.transaction(operations)
    id
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby examples/add_certificate.rb AREA LOOKUP CERT.pem [KEY.pem]" unless (3..4).cover?(ARGV.size)
  area, lookup, cert_path, key_path = ARGV
  cert = OpenSSL::X509::Certificate.new(File.binread(cert_path))
  key = key_path && OpenSSL::PKey.read(File.binread(key_path), ENV["KEY_PASSWORD"])
  id = CertificateExample.add(area: area, lookup: lookup, cert: cert, key: key,
    client: ENV.fetch("CCI_CLIENT_ID"), actor: ENV.fetch("CCI_ACTOR"))
  puts "Created certificate version #{id}"
end
