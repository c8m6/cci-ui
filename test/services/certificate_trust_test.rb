# frozen_string_literal: true

require "test_helper"

class CertificateTrustTest < ActiveSupport::TestCase
  Material = Struct.new(:certificate, :candidates)

  setup do
    travel_to Time.utc(2026, 9, 27, 12)
    @root, @key = issue(name: "Public fixture root", ca: true)
    @issuer, @issuer_key = issue(name: "Intermediate", issuer: @root, issuer_key: @key, ca: true)
    @leaf, = issue(issuer: @issuer, issuer_key: @issuer_key)
    @config = CertificateDiagnosticsConfiguration.new("CCI_TRUST_FIREFOX_ENABLED" => "true")
    @profile = { "roots" => { fp(@root) => { "pem" => @root.to_pem } }, "version" => "synthetic-1",
                 "release" => "Synthetic fixture", "source" => "https://example.test/fixture", "scope" => "mozilla_baseline",
                 "source_checked_at" => Time.current.iso8601, "expires_at" => 2.days.from_now }
  end

  teardown { travel_back }

  def fp(cert) = Certificates::Codec.fingerprint(cert)

  def evaluate(cert = @leaf, candidates = [@issuer])
    CertificateDiagnostics::Trust.new(Material.new(cert, candidates), @config, profile: @profile).call("trust_firefox")
  end

  test "TLS and CA paths use isolated vendor roots and persist exact chain identity" do
    result = evaluate
    assert_equal "good", result[:state]
    assert_equal [fp(@leaf), fp(@issuer), fp(@root)], result[:details]["path"]
    assert_equal fp(@root), result[:details]["root"]
    assert_equal "ca_path_trusted", evaluate(@root, [])[:reason]
    assert_equal "ca_path_trusted", evaluate(@issuer, [])[:reason]
    @profile["roots"] = { fp(@issuer) => { "pem" => @issuer.to_pem } }
    assert_equal "good", evaluate[:state]
  end

  test "different profiles distinguish private roots missing intermediates and invalid signatures" do
    other, = issue(name: "Different public root", ca: true)
    @profile["roots"] = { fp(other) => { "pem" => other.to_pem } }
    assert_equal "private_root", evaluate(@leaf, [@issuer, @root])[:reason]
    assert_equal "missing_intermediate", evaluate[:reason]
    assert_equal "unknown", evaluate(@leaf, [])[:state]
    @leaf.sign(@key, OpenSSL::Digest.new("SHA256"))
    assert_equal "invalid_path", evaluate[:reason]
  end

  test "expired future unsuitable usage and CA constraints cannot be green" do
    @leaf.not_after = 1.second.ago
    @leaf.sign(@issuer_key, OpenSSL::Digest.new("SHA256"))
    assert_equal "untrusted", evaluate[:state]
    @leaf.not_after = 1.day.from_now
    @leaf.not_before = 1.hour.from_now
    @leaf.sign(@issuer_key, OpenSSL::Digest.new("SHA256"))
    assert_equal "untrusted", evaluate[:state]
    @leaf.not_before = 1.day.ago
    factory = OpenSSL::X509::ExtensionFactory.new
    @leaf.add_extension(factory.create_extension("extendedKeyUsage", "clientAuth"))
    @leaf.sign(@issuer_key, OpenSSL::Digest.new("SHA256"))
    assert_equal "untrusted", evaluate[:state]
    @leaf.extensions = @leaf.extensions.reject { |ext| ext.oid == "extendedKeyUsage" }
    @leaf.sign(@issuer_key, OpenSSL::Digest.new("SHA256"))
    @issuer.extensions = @issuer.extensions.reject { |ext| ext.oid == "basicConstraints" }
    @issuer.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
    @issuer.sign(@key, OpenSSL::Digest.new("SHA256"))
    assert_equal "untrusted", evaluate[:state]
  end

  test "alternate cross signed path succeeds when the first path is private" do
    private_root, private_key = issue(name: "Private root", ca: true)
    alternate = OpenSSL::X509::Certificate.new(@issuer.to_der)
    alternate.issuer = private_root.subject
    alternate.sign(private_key, OpenSSL::Digest.new("SHA256"))
    assert_equal "good", evaluate(@leaf, [alternate, private_root, @issuer])[:state]
  end

  test "vendor cutoffs and unknown constraints are applied without discarding alternatives" do
    root = @profile["roots"][fp(@root)]
    root["distrust_after"] = @leaf.not_before.iso8601
    assert_equal "vendor_distrust", evaluate[:reason]
    root["distrust_after"] = (@leaf.not_before + 1).iso8601
    assert_equal "good", evaluate[:state]
    root["unsupported_policy"] = true
    assert_equal "unknown", evaluate[:state]
    root.delete("unsupported_policy")
    root["disabled_at"] = Time.current.iso8601
    assert_equal "vendor_distrust", evaluate[:reason]
  end

  test "profile sources are independently configured and invalid settings fail early" do
    TrustProfileConfiguration::DEFAULTS.each_key do |check|
      settings = { "CCI_#{check.upcase}_ENABLED" => "true" }
      settings["CCI_TRUST_CHROME_ENABLED"] = "true" if check == "chrome_policy"
      config = CertificateDiagnosticsConfiguration.new(settings)
      assert_equal settings.keys.size, config.enabled.size
      assert_equal 86_400, config.interval(check)
    end
    %w[CCI_TRUST_APPLE_TARGET CCI_TRUST_UBUNTU_TARGET CCI_TRUST_FIREFOX_MAX_AGE CCI_TRUST_REQUEST_TIMEOUT].each do |name|
      assert_raises(ArgumentError) { CertificateDiagnosticsConfiguration.new(name => "invalid") }
    end
  end

  test "vendor disable boundary expires persisted trust and schedules reevaluation exactly at the cutoff" do
    cutoff = 1.minute.from_now
    @profile["roots"][fp(@root)]["disabled_at"] = cutoff.iso8601
    outcome = evaluate
    assert_equal "good", outcome[:state]
    assert_equal cutoff, outcome[:expires_at]
    record = store(@leaf, chain: [@issuer, @root])
    CertificateDiagnosticCache.create!(cache_id: "profile:trust_firefox", metadata: {
      "target" => @config.trust["trust_firefox"]["target"], "version" => @profile["version"]
    })
    runner = CertificateDiagnostics::Runner.new(@config)
    runner.instance_variable_set(:@token, CertificateDiagnosticCache.acquire(CertificateDiagnostics::Runner::LEASE, seconds: 120))
    job = CertificateDiagnosticResult.create!(area: record.area, fingerprint: record.fingerprint,
      check_id: "trust_firefox", next_due_at: Time.current)
    runner.send(:publish, job, outcome, @leaf)
    assert_equal cutoff, job.reload.next_due_at
    assert_equal "good", job.display_state(@config, cutoff - 1)
    assert_equal "stale", job.display_state(@config, cutoff)
    assert_equal "stale", job.display_state(@config, cutoff + 1)
    travel_to cutoff
    assert_equal "vendor_distrust", evaluate[:reason]
    assert_equal "valid", record.status_key
  end

  test "a disabled anchor does not reject an alternative still valid path" do
    second, second_key = issue(name: "Second public root", ca: true)
    cross = OpenSSL::X509::Certificate.new(@issuer.to_der)
    cross.issuer = second.subject
    cross.sign(second_key, "SHA256")
    @profile["roots"][fp(second)] = { "pem" => second.to_pem }
    cutoff = 1.minute.from_now
    @profile["roots"][fp(@root)]["disabled_at"] = cutoff.iso8601
    candidates = [@issuer, cross]
    assert_equal cutoff, evaluate(@leaf, candidates)[:expires_at]
    travel_to cutoff
    result = evaluate(@leaf, candidates)
    assert_equal "good", result[:state]
    assert_equal fp(second), result[:details]["root"]
    assert_operator result[:expires_at], :>, cutoff
  end

  test "chain date transitions bound trust while issuance cutoffs do not expire already issued certificates" do
    cutoff = 1.minute.from_now
    @profile["roots"][fp(@root)]["distrust_after"] = cutoff.iso8601
    assert_equal @profile["expires_at"], evaluate[:expires_at]
    @issuer.not_after = cutoff
    @issuer.sign(@key, "SHA256")
    assert_equal cutoff, evaluate[:expires_at]
    travel_to cutoff
    assert_equal "untrusted", evaluate[:state]
  end

  test "NSS server trust selection joins DER identities and retains distrust cutoffs" do
    octal = ->(bytes) { bytes.bytes.map { |byte| format('\\%03o', byte) }.join }
    data = <<~DATA
      CKA_CLASS CK_OBJECT_CLASS CKO_CERTIFICATE
      CKA_VALUE MULTILINE_OCTAL
      #{octal.call(@root.to_der)}
      END
      CKA_NSS_SERVER_DISTRUST_AFTER MULTILINE_OCTAL
      #{octal.call("260927000000Z")}
      END
      CKA_CLASS CK_OBJECT_CLASS CKO_NSS_TRUST
      CKA_CERT_SHA1_HASH MULTILINE_OCTAL
      #{octal.call(Digest::SHA1.digest(@root.to_der))}
      END
      CKA_TRUST_SERVER_AUTH CK_TRUST CKT_NSS_TRUSTED_DELEGATOR
    DATA
    parser = CertificateDiagnostics::Sources::Mozilla.new(nil, target: "fixture", max_age: 1)
    assert_equal "2026-09-27T00:00:00Z", parser.parse(data).fetch(fp(@root)).fetch("distrust_after")
    assert_empty parser.parse(data.sub("CKT_NSS_TRUSTED_DELEGATOR", "CKT_NSS_NOT_TRUSTED"))
  end

  test "CCADB checks fingerprints and preserves unknown Apple restrictions" do
    parser = CertificateDiagnostics::Sources::Ccadb.new(nil, target: "fixture", max_age: 1)
    row = { "Apple Applied Constraints" => '{"allowed_policies":["Server Authentication"]}' }
    assert_equal({ "denied" => false }, parser.apple_constraints(row, fp(@root)))
    row["Apple Applied Constraints"] = '{"new_constraint":true}'
    assert_equal({ "unsupported_policy" => true }, parser.apple_constraints(row, fp(@root)))
  end

  test "textproto parser preserves alternatives and rejects unparsed syntax" do
    parsed = CertificateDiagnostics::Sources::TextProto.parse(
      'version_major: 1 trust_anchors { sha256_hex: "abc" constraints { min_version: "120" } constraints { future: true } }'
    )
    assert_equal 2, parsed["trust_anchors"].first["constraints"].size
    assert_raises(CertificateDiagnostics::Error) { CertificateDiagnostics::Sources::TextProto.parse("version_major: unknown") }
  end
  test "source archives enforce expansion limits and package checksum identity" do
    archive = CertificateDiagnostics::Sources::Archive.new(100)
    bytes = StringIO.new
    Zlib::GzipWriter.wrap(bytes) { |writer| writer.write("x" * 101) }
    assert_raises(CertificateDiagnostics::Error) { archive.gzip(bytes.string) }
    provider = CertificateDiagnostics::Sources::Ubuntu.new(nil, target: "noble-updates", max_age: 1, archive: archive)
    assert_raises(CertificateDiagnostics::Error) { provider.send(:verify_digest, "changed", Digest::SHA256.hexdigest("original")) }
    assert_raises(CertificateDiagnostics::Error) { archive.deb("not a package") { flunk "Invalid archive accepted" } }
  end
end
