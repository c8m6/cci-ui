# frozen_string_literal: true

require "test_helper"

class EmbeddedSctsTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 27, 12)
    @root, @root_key = issue(name: "Synthetic SCT Issuer", ca: true)
    @leaf, = issue(issuer: @root, issuer_key: @root_key)
    @log_key = OpenSSL::PKey::EC.generate("prime256v1")
    @timestamp = (Time.current.to_i - 60) * 1000
    @logs = {}
  end

  teardown { travel_back }

  def embed(key: @log_key, timestamp: @timestamp, tamper: false)
    # Construct the RFC 6962 precertificate signed input independently of the verifier.
    @leaf.extensions = @leaf.extensions.reject { |entry| entry.oid == "ct_precert_scts" }
    @leaf.sign(@root_key, "SHA256")
    tbs = OpenSSL::ASN1.decode(@leaf.to_der).value.first.to_der
    issuer_hash = Digest::SHA256.digest(@root.public_key.public_to_der)
    signed = "\x00\x00".b + [timestamp].pack("Q>") + "\x00\x01".b + issuer_hash +
             [tbs.bytesize >> 16, tbs.bytesize & 0xffff].pack("Cn") + tbs + "\x00\x00".b
    signature = key.sign("SHA256", signed)
    signature.setbyte(signature.bytesize - 1, signature.getbyte(signature.bytesize - 1) ^ 1) if tamper
    id = Digest::SHA256.digest(key.public_to_der)
    algorithm = key.is_a?(OpenSSL::PKey::RSA) ? 1 : 3
    sct = "\x00".b + id + [timestamp, 0, 4, algorithm, signature.bytesize].pack("Q>nCCn") + signature
    vector = [sct.bytesize].pack("n") + sct
    bytes = [vector.bytesize].pack("n") + vector
    @leaf.add_extension(OpenSSL::X509::Extension.new(CertificateDiagnostics::EmbeddedScts::SCT_OID,
      OpenSSL::ASN1::OctetString.new(bytes).to_der))
    @leaf.sign(@root_key, "SHA256")
    @id = Base64.strict_encode64(id)
    @logs[@id] = { "log_id" => @id, "key" => Base64.strict_encode64(key.public_to_der),
                    "state" => { "usable" => { "timestamp" => 1.year.ago.iso8601 } },
                    "temporal_interval" => { "start_inclusive" => Time.current.iso8601, "end_exclusive" => 1.year.from_now.iso8601 } }
  end

  def evidence(issuer = @root) = CertificateDiagnostics::EmbeddedScts.new(@leaf, issuer, @logs)

  test "ECDSA and RSA SCTs verify signatures over the reconstructed precertificate" do
    [@log_key, OpenSSL::PKey::RSA.new(2048)].each do |key|
      embed(key: key)
      assert_equal [@timestamp], evidence.timestamps
      assert_not evidence.unverified
    end
  end

  test "tampered signatures changed certificate unknown logs and wrong issuer never become timestamp evidence" do
    embed(tamper: true)
    assert_empty evidence.timestamps
    assert evidence.unverified
    embed
    @leaf.serial = 123
    @leaf.sign(@root_key, "SHA256")
    assert_empty evidence.timestamps
    embed
    other, = issue(ca: true)
    assert_empty evidence(other).timestamps
    @logs.clear
    assert_empty evidence.timestamps
  end

  test "retired log cutoff is exclusive and pending rejected and future timestamps are not evidence" do
    embed
    @logs[@id]["state"] = { "retired" => { "timestamp" => Time.at(@timestamp / 1000).utc.iso8601 } }
    assert_empty evidence.timestamps
    @logs[@id]["state"]["retired"]["timestamp"] = Time.at((@timestamp / 1000) + 1).utc.iso8601
    assert_equal [@timestamp], evidence.timestamps
    %w[pending rejected].each do |state|
      @logs[@id]["state"] = { state => { "timestamp" => 1.day.ago.iso8601 } }
      assert_empty evidence.timestamps
    end
    embed(timestamp: (Time.current.to_i * 1000) + 1)
    assert_empty evidence.timestamps
  end

  test "temporal interval covers certificate expiry rather than the SCT issuance time" do
    embed
    @logs[@id]["temporal_interval"] = { "start_inclusive" => @leaf.not_after.iso8601,
                                       "end_exclusive" => (@leaf.not_after + 1).iso8601 }
    assert_equal [@timestamp], evidence.timestamps
    @logs[@id]["temporal_interval"] = { "start_inclusive" => (@leaf.not_after - 1).iso8601,
                                       "end_exclusive" => @leaf.not_after.iso8601 }
    assert_empty evidence.timestamps
  end

  test "missing and malformed embedded evidence stays unavailable" do
    assert_empty evidence.timestamps
    @leaf.add_extension(OpenSSL::X509::Extension.new(CertificateDiagnostics::EmbeddedScts::SCT_OID,
      OpenSSL::ASN1::OctetString.new("\x00\x20short".b).to_der))
    assert_empty evidence.timestamps
    assert evidence.unverified
  end

  test "CT list signature key pin and signed publication age are independently checked" do
    key = OpenSSL::PKey::RSA.new(2048)
    key_digest = Digest::SHA256.hexdigest(key.public_to_der)
    data = JSON.generate("version" => "fixture.1", "log_list_timestamp" => Time.current.iso8601, "operators" => [])
    source = CertificateDiagnostics::Sources::CtLogs.new(nil, target: "v3", max_age: 86_400)
    verified = source.verify(data, key.sign("SHA256", data), key.public_to_pem, key_digest: key_digest)
    assert_equal "fixture.1", verified["version"]
    assert_raises(CertificateDiagnostics::Error) { source.verify(data, key.sign("SHA256", data), key.public_to_pem) }
    assert_raises(CertificateDiagnostics::Error) do
      source.verify("#{data} ", key.sign("SHA256", data), key.public_to_pem, key_digest: key_digest)
    end
    travel 86_401
    assert_raises(CertificateDiagnostics::Error) do
      source.verify(data, key.sign("SHA256", data), key.public_to_pem, key_digest: key_digest)
    end
  end
end
