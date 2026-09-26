# frozen_string_literal: true

# Durable CAS intents and one atomic Consul transaction make multi-area retries safe.
class CsrPublication
  def initialize(entry, identity:)
    @entry = entry
    @request = entry.certificate_request
    @identity = identity
    @connection = ConsulStore.client
    @writer = CciWriter.new(connection: @connection, prefix: ConsulStore.namespace)
  end

  def call(expected_index: 0, expected_indices: nil, confirm_overwrite: false)
    CsrWorkflow.authorize!(@identity, @request.areas)
    CatalogIndexer.synchronize do
      @entry.reload
      CsrNames.fail!(:stale) unless @request.latest_certificate&.id == @entry.id
      return @entry if @entry.state == "published"

      CatalogIndexer.new.consul
      CertificateAreaConfiguration.validate_fingerprint!(@entry.fingerprint, areas: @request.areas)
      verify!
      return @entry if @entry.state == "awaiting_issuer"

      prepare!(indices(expected_index, expected_indices), confirm_overwrite) if @entry.prepared.empty?
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
    CsrNames.fail!(:overwrite) if expected_indices.values.any?(&:positive?) && !confirm_overwrite

    cert = OpenSSL::X509::Certificate.new(@entry.pem)
    key = OpenSSL::PKey.read(CsrSecrets.decrypt(@request, "key"))
    preparations = @request.areas.to_h do |area|
      prepared = @writer.prepare(area: area, certid: @request.certid, cert: cert, key: key, tags: [],
        client: "cci-ui-csr", actor: @identity.uid, expected_index: expected_indices.fetch(area))
      [area, prepared]
    end
    versions = preparations.transform_values { |prepared| prepared.fetch(:version) }
    @entry.update!(prepared: { areas: preparations }, consul_version: versions.fetch(@request.area),
      consul_versions: versions, state: "publishing", error_code: nil)
  end

  def publish!
    preparations = area_preparations
    operations = preparations.values.flat_map { |prepared| prepared.fetch("operations") }
    events = preparations.map do |area, prepared|
      { action: "csr_publish", area: area, actor: @identity.uid,
        actor_display_name: @identity.display_name, references: [@request.id.to_s],
        details: { csr_id: @request.id, certid: @request.certid, certificate_id: @entry.id,
                   version: prepared.fetch("version"), target_areas: @request.areas } }
    end
    AuditEvent.record_mutations!(events: events) do
      @connection.transaction(operations) unless already_written?(preparations)
      @entry.update!(state: "published", published_at: Time.current, error_code: nil)
    end
    # Catalog refresh is independent of successful source publication.
    CatalogIndexer.new.consul
  rescue ConsulConnection::Conflict
    raise unless already_written?(preparations)

    @entry.update!(state: "published", published_at: Time.current, error_code: nil)
  end

  def area_preparations
    @entry.prepared["areas"] || { @request.area => @entry.prepared }
  end

  def already_written?(preparations)
    immutable = preparations.values.flat_map { |prepared| prepared.fetch("operations").drop(1) }
    values = immutable.map { |operation| @connection.get(operation.fetch("Key")) }
    return false if values.all?(&:nil?)
    unless values.zip(immutable).all? do |value, operation|
      value && value.fetch(:value) == Base64.strict_decode64(operation.fetch("Value"))
    end
      raise ConsulConnection::Conflict, "Publication target has changed"
    end

    true
  end

  def fail_publication!(code, clear: false)
    return @entry if @entry.state == "published"

    attributes = { state: "failed", error_code: code }
    attributes[:prepared] = {} if clear
    attributes[:consul_versions] = {} if clear
    @entry.update!(attributes)
    CsrAudit.record!("csr_publish", @request, @identity, outcome: "failed", code: code, certificate_id: @entry.id)
    @entry
  end
end
