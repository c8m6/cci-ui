# frozen_string_literal: true

require "test_helper"

class ChromePolicyTest < ActiveSupport::TestCase
  Material = Struct.new(:certificate, :candidates)
  Evidence = Struct.new(:timestamps, :unverified)

  setup do
    travel_to Time.utc(2026, 9, 27, 12)
    @root, @root_key = issue(name: "Synthetic Chrome Root", ca: true)
    @leaf, = issue(issuer: @root, issuer_key: @root_key)
    @schema = CertificateDiagnostics::ChromeConstraints::SCHEMA_DIGEST
    @anchor = { "sha256_hex" => [fp(@root)] }
    @config = CertificateDiagnosticsConfiguration.new("CCI_TRUST_CHROME_ENABLED" => "true", "CCI_CHROME_POLICY_ENABLED" => "true")
    @profile = { "roots" => { fp(@root) => { "pem" => @root.to_pem, "chrome" => @anchor } },
                 "schema_sha256" => @schema, "version" => "fixture", "release" => "Synthetic Chrome profile",
                 "source" => "Synthetic fixture", "scope" => "chrome_baseline", "source_checked_at" => Time.current.iso8601,
                 "expires_at" => 1.day.from_now }
  end

  teardown { travel_back }

  def fp(cert) = Certificates::Codec.fingerprint(cert)

  def constraints(sets, scts: nil)
    @anchor["constraints"] = sets
    CertificateDiagnostics::ChromeConstraints.new(@leaf, target: "154.0.8037.57", scts: scts).call(@anchor, schema_digest: @schema)
  end

  def policy
    CertificateDiagnostics::ChromePolicy.new(Material.new(@leaf, [@root]), @config, profile: @profile).call
  end

  test "alternative sets use OR fields use AND and version boundaries support partial versions" do
    assert_equal "good", constraints([{ "min_version" => ["154"], "max_version_exclusive" => ["155"] }])[:state]
    assert_equal "untrusted", constraints([{ "max_version_exclusive" => ["154"] }])[:state]
    assert_equal "untrusted", constraints([{ "min_version" => ["154.0.8037.58"] }])[:state]
    assert_equal "good", constraints([{ "min_version" => ["155"] }, { "max_version_exclusive" => ["155"] }])[:state]
    assert_equal "untrusted", constraints([{ "min_version" => ["155"], "max_version_exclusive" => ["155"] }])[:state]
  end

  test "validity start boundaries are inclusive for not after and exclusive for after" do
    boundary = @leaf.not_before.to_i
    assert_equal "good", constraints([{ "validity_starts_not_after_sec" => [boundary] }])[:state]
    assert_equal "untrusted", constraints([{ "validity_starts_after_sec" => [boundary] }])[:state]
    assert_equal "good", constraints([{ "validity_starts_after_sec" => [boundary - 1] }])[:state]
    assert_equal "untrusted", constraints([{ "validity_starts_not_after_sec" => [boundary - 1] }])[:state]
  end

  test "DNS subtrees cover every DNS SAN and respect label boundaries" do
    assert_equal "good", constraints([{ "permitted_dns_names" => ["example.test"] }])[:state]
    assert_equal "good", constraints([{ "permitted_dns_names" => [".example.test"] }])[:state]
    assert_equal "untrusted", constraints([{ "permitted_dns_names" => ["ample.test"] }])[:state]
    @leaf.extensions = @leaf.extensions.reject { |ext| ext.oid == "subjectAltName" }
    @leaf.add_extension(OpenSSL::X509::ExtensionFactory.new.create_extension("subjectAltName", "DNS:example.test,DNS:evil.test"))
    assert_equal "untrusted", constraints([{ "permitted_dns_names" => ["example.test"] }])[:state]
    assert_equal "good", constraints([{ "permitted_dns_names" => %w[example.test evil.test] }])[:state]
    assert_equal "untrusted", constraints([{ "permitted_dns_names" => %w[.example.test evil.test] }])[:state]
  end

  test "unknown schema fields and malformed rules cannot yield green" do
    assert_equal "unknown", constraints([{ "future_constraint" => [true] }])[:state]
    assert_equal "unknown", constraints([{ "min_version" => ["invalid"] }])[:state]
    assert_equal "unknown", constraints([{ "validity_starts_after_sec" => ["123"] }])[:state]
    @schema = "changed schema"
    assert_equal "unknown", constraints([])[:state]
    @schema = CertificateDiagnostics::ChromeConstraints::SCHEMA_DIGEST
    @anchor["new_anchor_constraint"] = [true]
    assert_equal "unknown", constraints([])[:state]
  end

  test "SCT rules accept verified boundaries and never infer rejection from unavailable external evidence" do
    set = [{ "sct_not_after_sec" => [100] }]
    assert_equal "unknown", constraints(set)[:state]
    assert_equal "unknown", constraints(set, scts: Evidence.new([100_001], false))[:state]
    assert_equal "good", constraints(set, scts: Evidence.new([100_000], false))[:state]
    set = [{ "sct_all_after_sec" => [100] }]
    assert_equal "untrusted", constraints(set, scts: Evidence.new([100_000, 100_001], false))[:state]
    assert_equal "good", constraints(set, scts: Evidence.new([100_001], false))[:state]
    assert_equal "unknown", constraints(set, scts: Evidence.new([100_001], true))[:state]
    assert_equal "unknown", constraints(set, scts: Evidence.new([], false))[:state]
  end

  test "policy retains successful baseline and path while SCT source is unavailable" do
    @anchor["constraints"] = [{ "sct_not_after_sec" => [Time.current.to_i] }]
    outcome = policy
    assert_equal "unknown", outcome[:state]
    assert_equal "good", outcome[:details]["baseline"]
    assert_equal "source_unavailable", outcome[:details]["ct_error"]
    assert_equal [fp(@leaf), fp(@root)], outcome[:details]["path"]
    @anchor.delete("constraints")
    assert_equal "good", policy[:state]
    @leaf = @root
    assert_equal "not_applicable", policy[:reason]
  end

  test "Chrome enforces root dates and name constraints only when its anchor flags request them" do
    @root.not_after = 1.hour.ago
    factory = OpenSSL::X509::ExtensionFactory.new
    @root.add_extension(factory.create_extension("nameConstraints", "permitted;DNS:other.test", true))
    @root.sign(@root_key, OpenSSL::Digest.new("SHA256"))
    @profile["roots"] = { fp(@root) => { "pem" => @root.to_pem, "chrome" => @anchor } }
    @anchor["sha256_hex"] = [fp(@root)]
    assert_equal "good", policy[:state]
    @anchor["enforce_anchor_expiry"] = [true]
    assert_equal "untrusted", policy[:state]
    @anchor["enforce_anchor_expiry"] = [false]
    @anchor["enforce_anchor_constraints"] = [true]
    assert_equal "untrusted", policy[:state]
    @anchor["enforce_anchor_constraints"] = [false]
    assert_equal "good", policy[:state]
  end

  test "policy requires Chrome and profile versions invalidate even without a CT cache" do
    assert_raises(ArgumentError) { CertificateDiagnosticsConfiguration.new("CCI_CHROME_POLICY_ENABLED" => "true") }
    before = CertificateDiagnostics::Profiles.version("chrome_policy", @config)
    CertificateDiagnosticCache.create!(cache_id: "profile:trust_chrome", metadata: {
      "target" => @config.trust["trust_chrome"]["target"], "version" => "new roots"
    })
    assert_not_equal before, CertificateDiagnostics::Profiles.version("chrome_policy", @config)
  end
  test "policy chooses an accepted alternate cross-signed path and binds anchor rules by fingerprint" do
    second, second_key = issue(name: "Alternate Public Root", ca: true)
    cross = OpenSSL::X509::Certificate.new(@root.to_der)
    cross.issuer = second.subject
    cross.sign(second_key, "SHA256")
    @anchor["constraints"] = [{ "min_version" => ["999"] }]
    @profile["roots"][fp(second)] = { "pem" => second.to_pem, "chrome" => { "sha256_hex" => [fp(second)] } }
    material = Material.new(@leaf, [@root, cross])
    result = CertificateDiagnostics::ChromePolicy.new(material, @config, profile: @profile).call
    assert_equal "good", result[:state]
    assert_equal fp(second), result[:details]["root"]
    @profile["roots"][fp(second)]["chrome"]["sha256_hex"] = ["wrong identity"]
    assert_equal "unknown", CertificateDiagnostics::ChromePolicy.new(material, @config, profile: @profile).call[:state]
  end
end
