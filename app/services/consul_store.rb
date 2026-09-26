# frozen_string_literal: true

require "cci_writer"

# Coordinates certificate mutations, CAS checks and durable PostgreSQL audit records.
class ConsulStore
  ROLLOUT_STATUSES = %w[active norollout delete].freeze
  def self.namespace = ENV.fetch("CONSUL_PREFIX", "cci")
  def self.client = ConsulConnection.new

  def self.prefix(area)
    raise Certificates::Error, I18n.t("errors.app.unknown_area") unless AreaConfiguration.ids.include?(area)

    "#{namespace}/#{area}"
  end

  def self.validate_certid!(certid)
    return if certid.is_a?(String) && certid.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)

    raise Certificates::Error,
      I18n.t("errors.app.certid_format")
  end

  def self.split_id(id)
    certid, version = id.to_s.split("/", 2)
    validate_certid!(certid)
    raise Certificates::Error, I18n.t("errors.app.missing_version") unless version&.match?(/\A[1-9][0-9]*\z/)

    [certid, Integer(version)]
  end

  def self.certid_snapshot(area, certid)
    validate_certid!(certid)
    client.get("#{prefix(area)}/certids/#{certid}")
  end

  def self.status_snapshot(record)
    certid_snapshot(record.area, record.certid) if record.source == "consul"
  end

  def self.rollout_status(entry)
    status = entry.fetch("status", "active")
    raise Certificates::Error, I18n.t("errors.app.stored_status") unless ROLLOUT_STATUSES.include?(status)

    status
  end

  def self.catalog_status(entry)
    archived = entry.fetch("archived", false)
    raise Certificates::Error, I18n.t("errors.app.stored_archive") unless [true, false].include?(archived)

    status = rollout_status(entry)
    raise Certificates::Error, I18n.t("errors.app.archived_delete") if archived && status != "delete"

    { rollout_status: status, archived: archived }
  end

  def self.get(area, id)
    split_id(id)
    raw = client.get("#{prefix(area)}/certs/#{id}")
    raise Certificates::Error, I18n.t("errors.app.missing_consul_certificate") unless raw

    JSON.parse(raw.fetch(:value))
  end

  def self.snapshot(cert, certid, id)
    AuditEvent.snapshot(cert).merge(source: "consul", source_id: id, certid: certid, kind: "selected")
  end

  def self.save(area:, cert:, key:, tags:, certid:, actor:, client:, expected_certid_index: nil, actor_display_name: nil)
    unless actor.is_a?(String) && actor.strip.present? && actor.length <= 255
      raise Certificates::Error,
        I18n.t("errors.app.actor_format")
    end

    prefix(area)
    writer = CciWriter.new(connection: self.client, prefix: namespace)
    prepared = writer.prepare(area: area, certid: certid, cert: cert, key: key, tags: tags,
      client: client, actor: actor, expected_index: expected_certid_index)
    id = "#{certid}/#{prepared.fetch(:version)}"
    details = { certificates: [snapshot(cert, certid, id)],
                previous_version: prepared[:previous]["active_version"], version: prepared[:version],
                tags: tags, has_key: !key.nil?, before: prepared[:previous], after: prepared[:updated] }
    AuditEvent.record_mutation!(action: "import", area: area, actor: actor,
      actor_display_name: actor_display_name, references: [id], details: details) do
      writer.commit(prepared)
    end
    id
  rescue ConsulConnection::Conflict
    message = expected_certid_index.nil? ? "errors.app.concurrent_change" : "errors.app.preview_changed"
    raise Certificates::Error, I18n.t(message)
  rescue ArgumentError => e
    raise Certificates::Error, e.message
  end

  def self.activate(area, id, actor:, actor_display_name: nil)
    certid, version = split_id(id)
    data = get(area, id)
    mutate(area, certid, actor: actor, actor_display_name: actor_display_name,
      action: "activate", id: id, data: data) do |entry|
      raise Certificates::Error, I18n.t("errors.app.archived_activation") if catalog_status(entry).fetch(:archived)

      entry.merge("active_version" => version)
    end
  end

  def self.set_status(area, id, status:, actor:, expected_certid_index:, actor_display_name: nil)
    raise Certificates::Error, I18n.t("errors.app.invalid_status") unless ROLLOUT_STATUSES.include?(status)
    raise Certificates::Error, I18n.t("errors.app.certid_changed") if expected_certid_index.nil?

    certid, = split_id(id)
    data = get(area, id)
    mutate(area, certid, actor: actor, actor_display_name: actor_display_name,
      action: "status_change", id: id, data: data, expected_index: expected_certid_index) do |entry|
      if catalog_status(entry).fetch(:archived) && status != "delete"
        raise Certificates::Error,
          I18n.t("errors.app.archived_reactivation")
      end

      entry.merge("status" => status)
    end
  end

  def self.archive(record, actor:, expected_certid_index:, actor_display_name: nil)
    raise Certificates::Error, I18n.t("errors.app.archive_consul_only") unless record.source == "consul"
    raise Certificates::Error, I18n.t("errors.app.certid_changed") if expected_certid_index.nil?

    data = { "snapshot" => record.attributes.slice("common_name", "subject", "issuer", "serial", "fingerprint",
      "source", "source_id", "certid").merge("kind" => "selected") }
    mutate(record.area, record.certid, actor: actor, actor_display_name: actor_display_name,
      action: "archive", id: record.source_id, data: data, expected_index: expected_certid_index) do |entry|
      next entry if catalog_status(entry).fetch(:archived)

      entry.merge("status" => "delete", "archived" => true, "archived_at" => Time.current.iso8601(6),
        "archived_by" => actor)
    end
  end

  def self.mutate(area, certid, actor:, action:, id:, data:, expected_index: nil, actor_display_name: nil)
    connection = client
    path = "#{prefix(area)}/certids/#{certid}"
    current = connection.get(path) || raise(Certificates::Error, I18n.t("errors.app.missing_certid"))
    raise Certificates::Error, I18n.t("errors.app.certid_changed") if expected_index && current.fetch(:index).to_s != expected_index.to_s

    entry = JSON.parse(current.fetch(:value))
    catalog_status(entry)
    updated = yield(entry)
    return if updated == entry

    updated = updated.merge("updated_at" => Time.current.iso8601(6), "client" => "cci-ui", "updated_by" => actor)
    certificate = data["snapshot"] || snapshot(OpenSSL::X509::Certificate.new(data.fetch("pem")), certid, id)
    details = { certificates: [certificate], previous_version: entry["active_version"], version: updated["active_version"],
                previous_status: entry["status"], status: updated["status"], previous_archived: entry.fetch("archived", false),
                archived: updated.fetch("archived", false), scope: "certid", before: entry, after: updated }
    details[:comment] = I18n.t("audit.archive_comment", locale: :en) if action == "archive"
    AuditEvent.record_mutation!(action: action, area: area, actor: actor,
      actor_display_name: actor_display_name, references: [id], details: details) do
      connection.transaction([ConsulConnection.set(path, updated, index: current.fetch(:index))])
    end
  rescue ConsulConnection::Conflict
    raise Certificates::Error, I18n.t("errors.app.concurrent_change")
  end
end
