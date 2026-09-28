# frozen_string_literal: true

require "test_helper"

class CertificateDiagnosticsTest < ActiveSupport::TestCase
  FakeMaterial = Struct.new(:certificate, :issuer) do
    def self_signed? = certificate.subject == certificate.issuer && certificate.verify(certificate.public_key)
  end
  FakeHttp = Struct.new(:bytes, :calls, :error) do
    def fetch(*)
      self.calls += 1
      raise CertificateDiagnostics::Error, error if error

      bytes
    end
  end

  setup do
    @config = CertificateDiagnosticsConfiguration.new("CCI_OCSP_ENABLED" => "true", "CCI_CRL_ENABLED" => "true")
    @root, @key = issue(name: "Diagnostic CA", ca: true)
    @leaf, = issue(issuer: @root, issuer_key: @key)
    factory = OpenSSL::X509::ExtensionFactory.new
    @leaf.add_extension(factory.create_extension("authorityInfoAccess", "OCSP;URI:http://ocsp.example.test/"))
    @leaf.add_extension(factory.create_extension("crlDistributionPoints", "URI:http://crl.example.test/list"))
    @leaf.sign(@key, OpenSSL::Digest.new("SHA256"))
    @material = FakeMaterial.new(@leaf, @root)
    @http = FakeHttp.new(nil, 0, nil)
  end

  def check(kind)
    CertificateDiagnostics::Revocation.new(@material, @config, http: @http, area: "zone_a").call(kind)
  end

  def ocsp(status: OpenSSL::OCSP::V_CERTSTATUS_GOOD, issuer: @root, signer: @root, key: @key,
           this_update: Time.current - 60, next_update: Time.current + 3600)
    basic = OpenSSL::OCSP::BasicResponse.new
    id = OpenSSL::OCSP::CertificateId.new(@leaf, issuer)
    basic.add_status(id, status, OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE, Time.current - 120, this_update, next_update, [])
    basic.sign(signer, key, [issuer])
    @http.bytes = OpenSSL::OCSP::Response.create(OpenSSL::OCSP::RESPONSE_STATUS_SUCCESSFUL, basic).to_der
  end

  def crl(revoked: false, expired: false, extension: nil, key: @key)
    list = OpenSSL::X509::CRL.new
    list.version = 1
    list.issuer = @root.subject
    list.last_update = Time.current - 3600
    list.next_update = expired ? Time.current - 60 : Time.current + 3600
    if revoked
      entry = OpenSSL::X509::Revoked.new
      entry.serial = @leaf.serial
      entry.time = Time.current - 120
      list.add_revoked(entry)
    end
    list.add_extension(extension) if extension
    list.sign(key, OpenSSL::Digest.new("SHA256"))
    @http.bytes = list.to_der
  end

  def ocsp_with_extension(level:, critical:)
    extension = OpenSSL::X509::Extension.new("1.2.3.4.5.6", OpenSSL::ASN1::Null.new(nil).to_der, critical)
    basic = OpenSSL::OCSP::BasicResponse.new
    basic.add_status(OpenSSL::OCSP::CertificateId.new(@leaf, @root), OpenSSL::OCSP::V_CERTSTATUS_GOOD,
      0, nil, Time.current - 60, Time.current + 3600, level == :single ? [extension] : [])
    basic.sign(@root, @key, [@root], 0, OpenSSL::Digest.new("SHA256"))
    signed = OpenSSL::ASN1.decode(basic.to_der)
    data = signed.value.first
    data.value.find { |node| node.is_a?(OpenSSL::ASN1::GeneralizedTime) }.value = Time.current
    if level == :response
      extensions = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1.decode(extension.to_der)])
      data.value << OpenSSL::ASN1::ASN1Data.new([extensions], 1, :CONTEXT_SPECIFIC)
    end
    signed.value[2] = OpenSSL::ASN1::BitString.new(@key.sign("SHA256", data.to_der))
    basic = OpenSSL::OCSP::BasicResponse.new(signed.to_der)
    @http.bytes = OpenSSL::OCSP::Response.create(OpenSSL::OCSP::RESPONSE_STATUS_SUCCESSFUL, basic).to_der
  end

  test "signed OCSP extensions are checked at both response levels without rejecting noncritical extensions" do
    travel_to Time.current.change(usec: 0) do
      %i[response single].each do |level|
        ocsp_with_extension(level: level, critical: false)
        assert_equal "good", check("ocsp")[:state], level.to_s
        ocsp_with_extension(level: level, critical: true)
        outcome = check("ocsp")
        assert_equal "unknown", outcome[:state], level.to_s
        assert_equal "unsupported_ocsp_extension", outcome[:reason]
        %i[en de].each do |locale|
          assert I18n.exists?("diagnostics.reasons.#{outcome[:reason]}", locale)
        end
      end
    end
  end

  test "OCSP requires current signed exact evidence and handles all statuses" do
    { OpenSSL::OCSP::V_CERTSTATUS_GOOD => "good", OpenSSL::OCSP::V_CERTSTATUS_REVOKED => "revoked",
      OpenSSL::OCSP::V_CERTSTATUS_UNKNOWN => "unknown" }.each do |status, state|
      ocsp(status: status)
      assert_equal state, check("ocsp")[:state]
    end
    ocsp(next_update: Time.current - 1)
    assert_equal "expired_evidence", check("ocsp")[:reason]
    ocsp(this_update: Time.current + 3600)
    assert_equal "invalid_time", check("ocsp")[:reason]
    wrong, wrong_key = issue(name: "Wrong CA", ca: true)
    ocsp(issuer: wrong, signer: wrong, key: wrong_key)
    assert_equal "invalid_signature", check("ocsp")[:reason]
    ocsp(issuer: wrong)
    assert_includes %w[wrong_certificate invalid_signature], check("ocsp")[:reason]
    signer, signer_key = issue(issuer: @root, issuer_key: @key)
    ocsp(signer: signer, key: signer_key)
    assert_equal "invalid_signature", check("ocsp")[:reason]
    signer.add_extension(OpenSSL::X509::ExtensionFactory.new.create_extension("extendedKeyUsage", "OCSPSigning"))
    signer.sign(@key, OpenSSL::Digest.new("SHA256"))
    ocsp(signer: signer, key: signer_key)
    assert_equal "good", check("ocsp")[:state]
  end

  test "CRLs verify signatures dates scope revocation and share durable downloads" do
    crl
    assert_equal "good", check("crl")[:state]
    retained = CertificateDiagnosticCache.where("cache_id LIKE 'crl:%'").first
    assert_equal @http.bytes, retained.payload
    assert_equal "http://crl.example.test/list", retained.metadata.fetch("url")
    assert_equal Digest::SHA256.hexdigest(@http.bytes), retained.metadata.fetch("sha256")
    assert_equal "good", check("crl")[:state]
    assert_equal 1, @http.calls
    CertificateDiagnosticCache.delete_all
    crl(revoked: true)
    assert_equal "revoked", check("crl")[:state]
    CertificateDiagnosticCache.delete_all
    crl(expired: true)
    assert_equal "expired_evidence", check("crl")[:reason]
    crl(key: OpenSSL::PKey::RSA.new(2048))
    assert_equal "invalid_signature", check("crl")[:reason]
    crl(extension: OpenSSL::X509::Extension.new("2.5.29.27", OpenSSL::ASN1::Integer.new(1).to_der, true))
    assert_equal "unsupported_crl_scope", check("crl")[:reason]
    crl(extension: OpenSSL::X509::Extension.new("issuingDistributionPoint", OpenSSL::ASN1::Sequence.new([]).to_der, true))
    assert_equal "unsupported_crl_scope", check("crl")[:reason]
  end

  test "OCSP retains original responder bytes and source identity" do
    ocsp
    assert_equal "good", check("ocsp")[:state]
    retained = CertificateDiagnosticCache.where("cache_id LIKE 'ocsp:%'").first
    assert_equal @http.bytes, retained.payload
    assert_equal "http://ocsp.example.test/", retained.metadata.fetch("url")
    assert_equal Digest::SHA256.hexdigest(@http.bytes), retained.metadata.fetch("sha256")
  end

  test "missing inputs malformed bytes and transport failures remain independent unknowns" do
    %w[ocsp crl].each do |kind|
      @http.bytes = "not evidence"
      assert_equal "malformed_evidence", check(kind)[:reason]
      @http.error = "network_error"
      assert_equal "network_error", check(kind)[:reason]
      @http.error = nil
      @material.issuer = nil
      assert_equal "missing_issuer", check(kind)[:reason]
      @material.issuer = @root
    end
    @material.certificate = issue(issuer: @root, issuer_key: @key).first
    assert_equal "missing_url", check("ocsp")[:reason]
    assert_equal "missing_url", check("crl")[:reason]
    @material.certificate = @root
    assert_equal "not_applicable", check("ocsp")[:reason]
  end

  test "network policy rejects rebinding private mapped IPv6 and metadata with narrow opt in" do
    http = CertificateDiagnostics::Http.new(@config)
    %w[127.0.0.1 169.254.169.254 10.0.0.1 ::1 ::ffff:127.0.0.1 fc00::1 2002:7f00:1::1].each do |ip|
      assert_not http.allowed_address?(ip), ip
    end
    assert http.allowed_address?("8.8.8.8")
    opted = CertificateDiagnostics::Http.new(CertificateDiagnosticsConfiguration.new("CCI_DIAGNOSTICS_ALLOWED_NETWORKS" => "10.2.0.0/16"))
    assert opted.allowed_address?("10.2.1.2")
    assert_not opted.allowed_address?("10.3.1.2")
    resolver = Object.new
    def resolver.getaddresses(*) = ["8.8.8.8", "127.0.0.1"]
    error = assert_raises(CertificateDiagnostics::Error) do
      CertificateDiagnostics::Http.new(@config, resolver: resolver).fetch("http://example.test/")
    end
    assert_equal "blocked_destination", error.message
  end

  test "configuration is strict independently disabled and scheduler is lease protected" do
    assert_empty CertificateDiagnosticsConfiguration.new({}).enabled
    assert_equal ["crl"], CertificateDiagnosticsConfiguration.new("CCI_CRL_ENABLED" => "true").enabled
    %w[CCI_OCSP_ENABLED CCI_CRL_INTERVAL CCI_DIAGNOSTICS_ALLOWED_NETWORKS CCI_EVIDENCE_REFRESH_INTERVAL].each do |key|
      assert_raises(ArgumentError) { CertificateDiagnosticsConfiguration.new(key => "invalid") }
    end
    token = CertificateDiagnosticCache.acquire("test", seconds: 30)
    assert token
    assert_nil CertificateDiagnosticCache.acquire("test", seconds: 30)
    CertificateDiagnosticCache.release("test", "wrong-owner")
    assert_nil CertificateDiagnosticCache.acquire("test", seconds: 30)
    CertificateDiagnosticCache.where(cache_id: "test").update_all(lease_until: 1.second.ago)
    assert CertificateDiagnosticCache.acquire("test", seconds: 30)
  end

  test "scheduling deduplicates material retains versions ignores timestamps and isolates areas" do
    record = store(@root, certid: "root")
    store(@root, certid: "copy")
    record.update!(archived: true, active: false, rollout_status: "delete")
    CertificateDiagnostics::Runner.run(@config)
    assert_equal 2, CertificateDiagnosticResult.count
    result = CertificateDiagnosticResult.find_by!(check_id: "ocsp")
    checked = result.checked_at
    assert_equal "not_applicable", result.reason
    CatalogIndexer.new.consul
    CertificateDiagnostics::Runner.run(@config)
    assert_equal checked, result.reload.checked_at
    store(@leaf, area: "zone_b", certid: "leaf")
    CertificateDiagnostics::Runner.run(@config)
    assert_equal "missing_issuer", CertificateDiagnosticResult.find_by!(area: "zone_b", check_id: "ocsp").reason
    assert_equal "valid", record.status_key
    CertificateDiagnostics::Runner.run(CertificateDiagnosticsConfiguration.new({}))
    assert result.reload.suspended
    CertificateDiagnostics::Runner.run(@config)
    assert_operator result.reload.checked_at, :>, checked
  end
  test "failed refreshes preserve evidence and fenced workers cannot publish" do
    record = store(@root)
    runner = CertificateDiagnostics::Runner.new(@config)
    token = CertificateDiagnosticCache.acquire(CertificateDiagnostics::Runner::LEASE, seconds: 30)
    runner.instance_variable_set(:@token, token)
    job = CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint,
      check_id: "ocsp", next_due_at: Time.current)
    outcome = { state: "revoked", reason: "revoked", expires_at: 1.hour.from_now }
    runner.send(:publish, job, outcome, @root)
    expiry = job.expires_at
    checked = job.checked_at
    runner.send(:publish, job, { state: "unknown", reason: "network_error" }, @root)
    assert_equal "revoked", job.reload.state
    assert_equal expiry, job.expires_at
    assert_equal checked, job.checked_at
    assert job.revoked_at
    assert_equal "stale", job.display_state(@config, expiry + 1)
    assert_equal "disabled", job.display_state(CertificateDiagnosticsConfiguration.new({}))
    CertificateDiagnosticCache.release(CertificateDiagnostics::Runner::LEASE, token)
    runner.send(:publish, job, { state: "good", reason: "good" }, @root)
    assert_equal "revoked", job.reload.state
  end

  test "bounded batches eventually advance archived jobs and never evaluate deleted material" do
    config = CertificateDiagnosticsConfiguration.new("CCI_OCSP_ENABLED" => "true", "CCI_DIAGNOSTICS_BATCH_SIZE" => "1")
    first = store(@root, certid: "one")
    second = store(issue(name: "Second CA", ca: true).first, certid: "two")
    second.update!(active: false, archived: true, rollout_status: "delete")
    CertificateDiagnostics::Runner.run(config)
    assert_equal 1, CertificateDiagnosticResult.where.not(checked_at: nil).count
    CertificateDiagnostics::Runner.run(config)
    assert_equal 2, CertificateDiagnosticResult.where.not(checked_at: nil).count
    first.update!(deleted_at: Time.current)
    CertificateDiagnostics::Runner.run(config)
    assert_not CertificateDiagnosticResult.exists?(fingerprint: first.fingerprint)
  end
end
