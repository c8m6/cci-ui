# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class CsrWorkflowTest < ActiveSupport::TestCase
  include CsrFixtures

  test "RSA and EC requests verify and secrets are encrypted with separate authenticated contexts" do
    [%w[RSA 2048], %w[EC 256]].each do |algorithm, size|
      request = create_csr(key_algorithm: algorithm, key_size: size, email: "csr@example.test")
      csr = OpenSSL::X509::Request.new(request.csr_pem)
      assert csr.verify(csr.public_key)
      assert_equal ["extReq"], csr.attributes.map(&:oid)
      assert_equal ["DNS:portal.example.test", "DNS:www.example.test", "IP:192.0.2.7"], request.sans
      password = CsrWorkflow.reveal(request, identity: csr_identity, confirmed: true)
      assert_operator password.length, :>=, 40
      refute_includes request.attributes.values.join, password
      refute_includes request.attributes.values.join, "PRIVATE KEY"
      assert csr.public_key.public_to_der == OpenSSL::PKey.read(CsrSecrets.decrypt(request, "key")).public_to_der
      assert_equal "succeeded", AuditEvent.where(action: "csr_reveal").last.details["outcome"]
      request.encrypted_revoke_password = request.encrypted_private_key
      assert_raises(Certificates::Error) { CsrSecrets.decrypt(request, "revoke") }
    end
  end

  test "defaults are configurable and explicit input overrides them" do
    original = ENV.fetch("CSR_DEFAULT_ORGANIZATION", nil)
    ENV["CSR_DEFAULT_ORGANIZATION"] = "Configured org"
    assert_equal "Configured org", create_csr.subject_fields["organization"]
    assert_equal "Custom org", create_csr(organization: "Custom org").subject_fields["organization"]
  ensure
    ENV["CSR_DEFAULT_ORGANIZATION"] = original
  end

  test "names normalize and deduplicate while invalid SANs and subjects fail closed" do
    assert_equal ["DNS:portal.example.test", "IP:2001:db8::1"],
      CsrNames.sans("PORTAL.example.test.", "DNS:portal.example.test IP:2001:db8::1 2001:0db8::1")
    ["bad/name", "a..example.test", "x.*.example.test", "999.1.1.1", "-bad.example.test"].each do |name|
      assert_raises(Certificates::Error) { create_csr(sans: name) }
    end
    assert_raises(Certificates::Error) { create_csr(common_name: "") }
    assert_raises(Certificates::Error) { create_csr(email: "bad name@example.test") }
    assert_raises(Certificates::Error) { create_csr(key_size: "1024") }
    assert_raises(Certificates::Error) { create_csr(digest: "SHA1") }
  end

  test "missing malformed and changed encryption keys never produce plaintext persistence" do
    request = create_csr
    original = ENV.fetch("ZONE_A_KEY")
    [nil, "invalid", Base64.strict_encode64("x" * 32)].each do |key|
      ENV["ZONE_A_KEY"] = key
      assert_raises(Certificates::Error) { CsrSecrets.decrypt(request, "revoke") }
      next if key&.length == original.length

      assert_no_difference "CertificateRequest.count" do
        assert_raises(Certificates::Error) { create_csr }
      end
    end
  ensure
    ENV["ZONE_A_KEY"] = original
  end

  test "roles and explicit disclosure confirmation are required" do
    request = create_csr
    assert_raises(Certificates::Error) { CsrWorkflow.reveal(request, identity: csr_identity, confirmed: false) }
    %w[reader writer key_exporter auditor].each do |role|
      identity = Identity.new(name: role, roles: ["zone_a_#{role}"])
      assert_raises(Certificates::Error) { CsrWorkflow.create(csr_input, identity: identity) }
      assert_raises(Certificates::Error) { CsrWorkflow.reveal(request, identity: identity, confirmed: true) }
    end
    assert_raises(Certificates::Error) { CsrWorkflow.reveal(request, identity: csr_identity("zone_b"), confirmed: true) }
    refute csr_identity.reader?("zone_a")
    refute csr_identity.writer?("zone_a")
  end

  test "audit failure rolls back CSR creation and prevents disclosure" do
    original = CsrAudit.method(:record!)
    CsrAudit.define_singleton_method(:record!) { |*| raise ActiveRecord::StatementInvalid, "test failure" }
    assert_no_difference "CertificateRequest.count" do
      assert_raises(ActiveRecord::StatementInvalid) { create_csr }
    end
  ensure
    CsrAudit.define_singleton_method(:record!, original)
  end
end
