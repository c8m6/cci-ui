# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class CsrSecretRotationTest < ActiveSupport::TestCase
  include CsrFixtures

  test "rotation preserves both secrets and invalidates the previous key" do
    request = create_csr
    old_key = ENV.fetch("ZONE_A_KEY")
    new_key = Base64.strict_encode64("n" * 32)
    password = CsrSecrets.decrypt(request, "revoke")
    key = CsrSecrets.decrypt(request, "key")
    assert_equal 1, CsrSecretRotation.call(area: "zone_a", old_key: old_key, new_key: new_key, actor: "operator")
    request.reload
    assert_equal password, CsrSecrets.decrypt(request, "revoke", encryption_key: new_key)
    assert_equal key, CsrSecrets.decrypt(request, "key", encryption_key: new_key)
    assert_raises(Certificates::Error) { CsrSecrets.decrypt(request, "revoke", encryption_key: old_key) }
    assert_equal "csr_rotate", AuditEvent.last.action
    refute_includes AuditEvent.last.details.to_json, password
  end

  test "one damaged secret rolls back rotation of the entire area" do
    first = create_csr
    second = create_csr
    original = first.encrypted_revoke_password
    second.update!(encrypted_revoke_password: "invalid")
    assert_no_difference "AuditEvent.count" do
      assert_raises(Certificates::Error) do
        CsrSecretRotation.call(area: "zone_a", old_key: ENV.fetch("ZONE_A_KEY"),
          new_key: Base64.strict_encode64("n" * 32), actor: "operator")
      end
    end
    assert_equal original, first.reload.encrypted_revoke_password
  end

  test "pending intents block rotation and empty explicit keys are rejected" do
    request = create_csr
    entry = upload_csr(request)
    entry.update!(prepared: { operations: [] }, state: "publishing")
    assert_raises(Certificates::Error) do
      CsrSecretRotation.call(area: "zone_a", old_key: ENV.fetch("ZONE_A_KEY"),
        new_key: Base64.strict_encode64("n" * 32), actor: "operator")
    end
    assert_raises(ArgumentError) do
      CsrSecretRotation.call(area: "zone_a", old_key: nil, new_key: nil, actor: "operator")
    end
  end

  test "ciphertext tampering and cross-request copying fail authentication" do
    first = create_csr
    second = create_csr
    refute_equal CsrSecrets.decrypt(first, "revoke"), CsrSecrets.decrypt(second, "revoke")
    second.encrypted_revoke_password = first.encrypted_revoke_password
    assert_raises(Certificates::Error) { CsrSecrets.decrypt(second, "revoke") }
    envelope = JSON.parse(first.encrypted_revoke_password)
    envelope["tag"] = Base64.strict_encode64("x" * 16)
    first.encrypted_revoke_password = envelope.to_json
    assert_raises(Certificates::Error) { CsrSecrets.decrypt(first, "revoke") }
  end

  test "failed audit prevents password disclosure" do
    request = create_csr
    original = CsrAudit.method(:record!)
    CsrAudit.define_singleton_method(:record!) { |*| raise ActiveRecord::StatementInvalid, "audit unavailable" }
    assert_raises(ActiveRecord::StatementInvalid) do
      CsrWorkflow.reveal(request, identity: csr_identity, confirmed: true)
    end
  ensure
    CsrAudit.define_singleton_method(:record!, original) if original
  end
end
