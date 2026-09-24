# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class CsrPublicationTest < ActiveSupport::TestCase
  include CsrFixtures

  test "matching certificate publishes once and retains the encrypted revoke password" do
    request = create_csr
    encrypted = request.encrypted_revoke_password
    entry = upload_csr(request)
    stale_entry = CsrCertificate.find(entry.id)
    2.times { CsrPublication.new(entry, identity: csr_identity).call }
    assert_raises(Certificates::Error) do
      CsrUpload.add_issuers(request, stale_entry, data: entry.pem, identity: csr_identity)
    end
    assert_equal "published", entry.reload.state
    assert_equal 1, entry.consul_version
    assert_equal encrypted, request.reload.encrypted_revoke_password
    assert_equal 1, JSON.parse(ConsulStore.certid_snapshot("zone_a", "portal")[:value])["latest_version"]
    assert Certificate.exists?(area: "zone_a", certid: "portal")
  end

  test "missing issuer is retained and later catalog discovery allows publication" do
    request = create_csr
    issuer, key = issue(name: "CA.example.test", ca: true)
    entry = upload_csr(request, issued_for(request, issuer: issuer, issuer_key: key))
    assert_equal "awaiting_issuer", entry.state
    CsrPublication.new(entry, identity: csr_identity).call
    assert_nil ConsulStore.certid_snapshot("zone_a", "portal")
    store(issuer, area: "zone_b", certid: "ca")
    assert_equal "awaiting_issuer", CsrPublication.new(entry, identity: csr_identity).call.state
    store(issuer, certid: "ca")
    assert_equal "published", CsrPublication.new(entry, identity: csr_identity).call.state
  end

  test "issuer bundle verifies and wrong keys names SANs and invalid formats are rejected" do
    request = create_csr
    issuer, key = issue(name: "CA.example.test", ca: true)
    cert = issued_for(request, issuer: issuer, issuer_key: key)
    entry = CsrUpload.call(request, data: cert.to_pem + issuer.to_pem, identity: csr_identity)
    assert_equal "pending", entry.state
    [issue.first.to_pem, issued_for(request, common_name: "wrong.test").to_pem,
      issued_for(request, sans: ["DNS:portal.example.test"]).to_pem, "garbage",
      cert.to_pem + CsrSecrets.decrypt(request, "key")].each do |data|
      assert_raises(Certificates::Error) { CsrUpload.call(request, data: data, identity: csr_identity, replace: true) }
    end
    bad = issued_for(request, issuer: issuer, issuer_key: OpenSSL::PKey::RSA.new(2048))
    assert_raises(Certificates::Error) do
      CsrUpload.call(request, data: bad.to_pem + issuer.to_pem, identity: csr_identity, replace: true)
    end
  end

  test "replacement and existing CertID need explicit confirmation and fresh CAS index" do
    request = create_csr
    entry = upload_csr(request)
    CsrPublication.new(entry, identity: csr_identity).call
    replacement = issued_for(request, serial: 2)
    assert_raises(Certificates::Error) { upload_csr(request, replacement) }
    assert_raises(Certificates::Error) { upload_csr(request, OpenSSL::X509::Certificate.new(entry.pem), replace: true) }
    next_entry = upload_csr(request, replacement, replace: true)
    assert_equal "failed", CsrPublication.new(next_entry, identity: csr_identity).call.state
    index = ConsulStore.certid_snapshot("zone_a", "portal")[:index]
    assert_equal "failed", CsrPublication.new(next_entry, identity: csr_identity).call(expected_index: index).state
    result = CsrPublication.new(next_entry, identity: csr_identity).call(expected_index: index, confirm_overwrite: true)
    assert_equal "published", result.state
    assert_equal 2, result.consul_version
    assert_equal 2, request.csr_certificates.count
  end

  test "adding a missing issuer verifies the saved certificate without publishing" do
    request = create_csr
    issuer, key = issue(name: "Issuer.example.test", ca: true)
    entry = upload_csr(request, issued_for(request, issuer: issuer, issuer_key: key))
    assert_raises(Certificates::Error) { CsrUpload.add_issuers(request, entry, data: "invalid", identity: csr_identity) }
    assert_equal "rejected", AuditEvent.where(action: "csr_verify").last.details["outcome"]
    assert_equal "awaiting_issuer", entry.reload.state
    CsrUpload.add_issuers(request, entry, data: issuer.to_pem, identity: csr_identity)
    assert_equal "pending", entry.reload.state
    assert_nil ConsulStore.certid_snapshot("zone_a", "portal")
    assert_equal "published", CsrPublication.new(entry, identity: csr_identity).call.state
  end

  test "single DER is accepted but trailing data and invalid validity intervals are rejected" do
    request = create_csr
    cert = issued_for(request)
    assert_equal cert.to_der, CsrCertificateCheck.parse(cert.to_der).first.to_der
    assert_raises(Certificates::Error) { CsrCertificateCheck.parse("#{cert.to_der}junk") }
    cert.not_after = cert.not_before
    cert.sign(OpenSSL::PKey.read(CsrSecrets.decrypt(request, "key")), OpenSSL::Digest.new("SHA256"))
    assert_raises(Certificates::Error) { upload_csr(request, cert) }
  end

  test "expired certificates retain their validity dates and can be published" do
    request = create_csr
    cert = issued_for(request)
    cert.not_before = Time.now - 7200
    cert.not_after = Time.now - 3600
    cert.sign(OpenSSL::PKey.read(CsrSecrets.decrypt(request, "key")), OpenSSL::Digest.new("SHA256"))
    entry = upload_csr(request, cert)
    assert_operator entry.not_after, :<, Time.current
    assert_equal "published", CsrPublication.new(entry, identity: csr_identity).call.state
  end

  test "timeout before or after commit retains intent and retries without duplicate versions" do
    original = ConsulStore.method(:client)
    [false, true].each do |after_commit|
      clear_consul
      request = create_csr
      entry = upload_csr(request)
      connection = original.call
      transaction = connection.method(:transaction)
      connection.define_singleton_method(:transaction) do |operations|
        transaction.call(operations) if after_commit
        raise ConsulConnection::Error, "simulated lost response"
      end
      ConsulStore.define_singleton_method(:client) { connection }
      assert_equal "failed", CsrPublication.new(entry, identity: csr_identity).call.state
      assert entry.reload.prepared.any?
      assert_raises(Certificates::Error) { upload_csr(request, issued_for(request, serial: 2), replace: true) }
      ConsulStore.define_singleton_method(:client, original)
      assert_equal "published", CsrPublication.new(entry, identity: csr_identity).call.state
      assert_equal 1, JSON.parse(ConsulStore.certid_snapshot("zone_a", "portal")[:value])["latest_version"]
    end
  ensure
    ConsulStore.define_singleton_method(:client, original) if original
  end
end
