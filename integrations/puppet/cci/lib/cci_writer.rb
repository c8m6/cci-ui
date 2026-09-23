# frozen_string_literal: true

require_relative "consul_connection"
require_relative "area_secrets"
require_relative "certificates/vault"
require "digest"
require "time"

# The caller may persist an audit intent between prepare and commit. Preparing
# reads one certid record; committing publishes all keys in one transaction.
class CciWriter
  attr_reader :connection, :prefix

  def initialize(connection: ConsulConnection.new, prefix: "cci")
    @connection = connection
    @prefix = prefix
  end

  # Capture the current CAS index without writing. A caller can persist an audit
  # intent before commit publishes the public record and encrypted key atomically.
  def prepare(area:, certid:, cert:, key: nil, tags: [], client: "puppet", actor: nil, encryption_key: nil,
              expected_index: nil)
    validate_input(area: area, certid: certid, client: client, actor: actor, tags: tags, cert: cert, key: key)

    base = "#{prefix}/#{area}"
    path = "#{base}/certids/#{certid}"
    snapshot = connection.get(path)
    index = snapshot ? snapshot.fetch(:index) : 0
    raise ConsulConnection::Conflict, "Certificate changed since preview" if expected_index && expected_index != index

    entry = snapshot ? JSON.parse(snapshot.fetch(:value)) : {}
    status, version = next_version(entry)
    now = Time.now.utc.iso8601(6)
    data = { "pem" => cert.to_pem, "tags" => tags, "has_key" => !key.nil?,
             "created_at" => now, "client" => client }
    data["created_by"] = actor if actor
    updated = entry.merge("active_version" => version, "latest_version" => version, "status" => status,
      "updated_at" => now, "client" => client)
    updated.delete("updated_by")
    updated["updated_by"] = actor if actor
    operations = [ConsulConnection.set(path, updated, index: index),
      ConsulConnection.set("#{base}/certs/#{certid}/#{version}", data, index: 0)]
    if key
      # Bind the envelope to the immutable certificate version, as Rails does.
      envelope = Certificates::Vault.encrypt(key.private_to_pem, area: area, id: "#{certid}/#{version}",
        encryption_key: encryption_key || AreaSecrets.fetch(area))
      operations << ConsulConnection.set("#{base}/keys/#{certid}/#{version}", envelope, index: 0)
    end
    { version: version, data: data, previous: entry, updated: updated, operations: operations }
  end

  # Every operation uses CAS so a conflict leaves the entire batch unapplied.
  def commit(prepared)
    connection.transaction(prepared.fetch(:operations))
    prepared.fetch(:version)
  end

  def save(**) = commit(prepare(**))

  private

  # Validate caller-owned metadata before constructing Consul paths or reading state.
  def validate_input(area:, certid:, client:, actor:, tags:, cert:, key:)
    validate_identifiers(area, certid, client)
    raise ArgumentError, "Invalid actor" if actor && (!actor.is_a?(String) || actor.strip.empty? || actor.length > 255)
    raise ArgumentError, "Invalid tags" unless tags.is_a?(Array) && tags.all?(String)
    raise ArgumentError, "Certificate and key do not match" if key && !cert.check_private_key(key)
  end

  # Preserve rollout/archive state while allocating a monotonically increasing version.
  def next_version(entry)
    status = entry.fetch("status", "active")
    raise ArgumentError, "Invalid status" unless %w[active norollout delete].include?(status)

    archived = entry.fetch("archived", false)
    raise ArgumentError, "Invalid archive state" unless [true, false].include?(archived) && (!archived || status == "delete")

    latest = entry.fetch("latest_version", 0)
    raise ArgumentError, "Invalid latest version" unless latest.is_a?(Integer) && latest >= 0

    version = latest + 1
    [status, version]
  end

  def validate_identifiers(area, certid, client)
    raise ArgumentError, "Invalid area" unless area.is_a?(String) && area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    raise ArgumentError, "Invalid certid" unless certid.is_a?(String) && certid.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise ArgumentError, "Invalid client" unless client.is_a?(String) && client.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
  end
end
