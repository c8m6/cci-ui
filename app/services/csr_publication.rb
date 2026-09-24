# frozen_string_literal: true

# Durable CAS intents and immutable-value reconciliation make retries safe after lost replies.
class CsrPublication
  def initialize(entry, identity:)
    @entry = entry
    @request = entry.certificate_request
    @identity = identity
    @connection = ConsulStore.client
    @writer = CciWriter.new(connection: @connection, prefix: ConsulStore.namespace)
  end

  def call(expected_index: 0, confirm_overwrite: false)
    CsrWorkflow.authorize!(@identity, @request.area)
    CatalogIndexer.synchronize do
      @entry.reload
      CsrNames.fail!(:stale) unless @request.latest_certificate&.id == @entry.id
      return @entry if @entry.state == "published"

      verify!
      return @entry if @entry.state == "awaiting_issuer"

      prepare!(expected_index, confirm_overwrite) if @entry.prepared.empty?
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

  def verify!
    result = CsrCertificateCheck.verify(OpenSSL::X509::Certificate.new(@entry.pem),
      area: @request.area, issuer_pems: @entry.issuer_pems)
    if result == "missing"
      @entry.update!(state: "awaiting_issuer", error_code: "issuer_missing")
      return
    end
    CsrNames.fail!(:signature) if result == "invalid"

    @entry.update!(verified_at: Time.current, state: @entry.prepared.empty? ? "pending" : "publishing", error_code: nil)
  end

  def prepare!(expected_index, confirm_overwrite)
    CsrNames.fail!(:overwrite) unless expected_index.to_i.zero? || confirm_overwrite

    cert = OpenSSL::X509::Certificate.new(@entry.pem)
    key = OpenSSL::PKey.read(CsrSecrets.decrypt(@request, "key"))
    prepared = @writer.prepare(area: @request.area, certid: @request.certid, cert: cert, key: key, tags: [],
      client: "cci-ui-csr", actor: @identity.name, expected_index: Integer(expected_index))
    @entry.update!(prepared: prepared, consul_version: prepared.fetch(:version), state: "publishing", error_code: nil)
  end

  def publish!
    # Operation hashes have string keys in the Consul transport contract.
    operations = @entry.prepared.fetch("operations")
    AuditEvent.record_mutation!(action: "csr_publish", area: @request.area, actor: @identity.name,
      references: [@request.id.to_s], details: { csr_id: @request.id, certid: @request.certid,
                                                 certificate_id: @entry.id, version: @entry.consul_version }) do
      @writer.commit(version: @entry.consul_version, operations: operations) unless already_written?(operations)
      @entry.update!(state: "published", published_at: Time.current, error_code: nil)
    end
    # Catalog refresh is independent of successful source publication.
    CatalogIndexer.new.consul
  rescue ConsulConnection::Conflict
    raise unless already_written?(operations)

    @entry.update!(state: "published", published_at: Time.current, error_code: nil)
  end

  def already_written?(operations)
    immutable = operations.drop(1)
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
    @entry.update!(attributes)
    CsrAudit.record!("csr_publish", @request, @identity, outcome: "failed", code: code, certificate_id: @entry.id)
    @entry
  end
end
