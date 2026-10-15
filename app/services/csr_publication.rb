# frozen_string_literal: true

# Durable CAS intents preserve atomic writes and safe retries within one area.
class CsrPublication
  def initialize(entry, identity:)
    @entry = entry
    @request = entry.certificate_request
    @identity = identity
  end

  def call(expected_index: 0, expected_indices: nil, confirm_overwrite: false)
    CertificateAreaConfiguration.validate_selection!(@request.areas)
    CsrWorkflow.authorize!(@identity, @request.areas)
    CatalogIndexer.synchronize do
      @entry.reload
      CsrNames.fail!(:stale) if (area_preparations.keys - @request.areas).any?
      CsrNames.fail!(:stale) unless @request.latest_certificate&.id == @entry.id
      return @entry if @entry.state == "published"

      CatalogIndexer.new.consul
      verify!
      return @entry if @entry.state == "awaiting_issuer"

      prepare!(indices(expected_index, expected_indices), confirm_overwrite) if (@request.areas - area_preparations.keys).any?
      publish!
      @entry
    rescue ConsulConnection::Conflict
      fail_publication!("conflict", clear: true)
    rescue ConsulConnection::Error
      fail_publication!("consul")
    rescue Certificates::Error
      fail_publication!("publication")
    end
  end

  private

  def indices(expected_index, expected_indices)
    return @request.areas.to_h { |area| [area, Integer(expected_index)] } unless expected_indices

    @request.areas.to_h { |area| [area, Integer(expected_indices.fetch(area))] }
  rescue KeyError, ArgumentError, TypeError
    CsrNames.fail!(:stale)
  end

  def verify!
    cert = OpenSSL::X509::Certificate.new(@entry.pem)
    results = @request.areas.map do |area|
      CsrCertificateCheck.verify(cert, area: area, issuer_pems: @entry.issuer_pems)
    end
    CsrNames.fail!(:signature) if results.include?("invalid")
    if results.include?("missing")
      @entry.update!(state: "awaiting_issuer", error_code: "issuer_missing")
      return
    end

    @entry.update!(verified_at: Time.current, state: @entry.prepared.empty? ? "pending" : "publishing", error_code: nil)
  end

  def prepare!(expected_indices, confirm_overwrite)
    existing = area_preparations
    missing_indices = expected_indices.except(*existing.keys)
    CsrNames.fail!(:overwrite) if missing_indices.values.any?(&:positive?) && !confirm_overwrite

    cert = OpenSSL::X509::Certificate.new(@entry.pem)
    key = OpenSSL::PKey.read(CsrSecrets.decrypt(@request, "key"))
    preparations = @request.areas.to_h do |area|
      next [area, existing.fetch(area).deep_symbolize_keys] if existing.key?(area)

      writer = CciWriter.new(connection: ConsulStore.client(area), prefix: ConsulStore.namespace(area))
      prepared = writer.prepare(area: area, certid: @request.certid, cert: cert, key: key, tags: [],
        client: "cci-ui-csr", actor: @identity.uid, expected_index: expected_indices.fetch(area))
      [area, prepared]
    end
    versions = preparations.transform_values { |prepared| prepared.fetch(:version) }
    @entry.update!(prepared: { areas: preparations }, consul_version: versions.fetch(@request.area),
      consul_versions: versions, state: "publishing", error_code: nil)
  end

  def publish!
    preparations = area_preparations
    completed, pending = preparations.partition { |area, prepared| already_written?(area => prepared) }.map(&:to_h)
    record_confirmed!(completed)
    pending.each { |area, prepared| publish_batch!(area => prepared) }
    @entry.update!(state: "published", published_at: Time.current, error_code: nil)
    # Catalog refresh is independent of successful source publication.
    CatalogIndexer.new.consul
  end

  def publish_batch!(preparations)
    connection = ConsulStore.client(preparations.keys.fetch(0))
    AuditEvent.record_mutations!(events: audit_events(preparations)) do
      connection.transaction(preparations.values.flat_map { |prepared| prepared.fetch("operations") })
    end
  rescue ConsulConnection::Conflict
    raise unless already_written?(preparations)

    record_confirmed!(preparations)
  end

  def audit_events(preparations)
    preparations.map do |area, prepared|
      { action: "csr_publish", area: area, actor: @identity.uid,
        actor_display_name: @identity.display_name, references: [@request.id.to_s],
        details: { csr_id: @request.id, certid: @request.certid, certificate_id: @entry.id,
                   version: prepared.fetch("version"), target_areas: @request.areas } }
    end
  end

  # A lost response leaves an unknown audit outcome. Record the verified receipt
  # without rewriting Consul or duplicating an already successful audit entry.
  def record_confirmed!(preparations)
    audit_events(preparations).each do |event|
      receipt = event.fetch(:details).slice(:certificate_id, :version).merge(outcome: "succeeded")
      next if AuditEvent.where(action: "csr_publish", area: event.fetch(:area)).where("details @> ?::jsonb", receipt.to_json).exists?

      AuditEvent.create!(**event.except(:details), details: event.fetch(:details).merge(outcome: "succeeded", code: "reconciled"))
    end
  end

  def area_preparations
    return {} if @entry.prepared.empty?

    @entry.prepared["areas"] || { @request.area => @entry.prepared }
  end

  def already_written?(preparations)
    immutable = preparations.flat_map do |area, prepared|
      connection = ConsulStore.client(area)
      prepared.fetch("operations").drop(1).map { |operation| [connection.get(operation.fetch("Key")), operation] }
    end
    values = immutable.map(&:first)
    return false if values.all?(&:nil?)
    unless immutable.all? do |value, operation|
      value && value.fetch(:value) == Base64.strict_decode64(operation.fetch("Value"))
    end
      raise ConsulConnection::Conflict, "Publication target has changed"
    end

    true
  end

  def fail_publication!(code, clear: false)
    return @entry if @entry.state == "published"

    attributes = { state: "failed", error_code: code }
    attributes.merge!(retained_preparations) if clear
    @entry.update!(attributes)
    CsrAudit.record!("csr_publish", @request, @identity, outcome: "failed", code: code, certificate_id: @entry.id)
    @entry
  end

  # Never discard a receipt for an area already committed, including a lost reply.
  def retained_preparations
    completed = area_preparations.select do |area, prepared|
      already_written?(area => prepared)
    rescue ConsulConnection::Conflict
      false
    end
    { prepared: completed.empty? ? {} : { areas: completed },
      consul_versions: completed.transform_values { |prepared| prepared.fetch("version") } }
  rescue ConsulConnection::Error
    {} # Unknown outcomes retain the complete intent for a safe retry.
  end
end
