# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class CsrDeletionTest < ActionDispatch::IntegrationTest
  include CsrFixtures

  test "confirmed deletion retains secrets audits the actor and hides every direct action" do
    csr = create_csr
    original = csr.attributes.slice("csr_pem", "encrypted_private_key", "encrypted_revoke_password")
    post local_login_path, params: { identity: "zone_a_csr" }
    get certificate_request_path(csr)
    assert_select 'form[action=?] input[name="confirm_delete"]', certificate_request_path(csr)
    delete certificate_request_path(csr), params: { confirm_delete: "1" }
    assert_redirected_to certificate_requests_path
    assert csr.reload.deleted_at
    assert_equal "Zone A · CSR", csr.deleted_by
    assert_equal original, csr.attributes.slice(*original.keys)
    assert_equal "succeeded", AuditEvent.find_by!(action: "csr_delete").details["outcome"]
    assert AuditEvent.exists?(action: "csr_create")
    assert_equal "CSR gelöscht", AuditEvent.action_label("csr_delete")
    get certificate_requests_path, as: :json
    assert_empty response.parsed_body["open"]
    get certificate_request_path(csr)
    assert_response :not_found
    get download_certificate_request_path(csr)
    assert_response :not_found
    %i[reveal upload issuers publish].each do |action|
      post public_send("#{action}_certificate_request_path", csr)
      assert_response :not_found
    end
    delete certificate_request_path(csr), params: { confirm_delete: "1" }
    assert_response :not_found
  end

  test "confirmation CSR permissions and current uploaded state are mandatory" do
    csr = create_csr
    post local_login_path, params: { identity: "zone_b_csr" }
    delete certificate_request_path(csr), params: { confirm_delete: "1" }
    assert_response :not_found
    post local_login_path, params: { identity: "zone_a_writer" }
    delete certificate_request_path(csr), params: { confirm_delete: "1" }
    assert_response :forbidden
    post local_login_path, params: { identity: "zone_a_csr" }
    delete certificate_request_path(csr), as: :json
    assert_response :unprocessable_content
    assert_nil csr.reload.deleted_at
    entry = upload_csr(csr)
    delete certificate_request_path(csr), params: { confirm_delete: "1" }, as: :json
    assert_response :unprocessable_content
    CsrPublication.new(entry, identity: csr_identity).call
    delete certificate_request_path(csr), params: { confirm_delete: "1" }, as: :json
    assert_response :unprocessable_content
    assert_nil csr.reload.deleted_at
  end

  test "stale service objects cannot upload reveal or delete after deletion" do
    csr = create_csr
    stale = CertificateRequest.find(csr.id)
    material = issued_for(csr).to_pem
    CsrWorkflow.delete(csr, identity: csr_identity, confirmed: true)
    assert_raises(Certificates::Error) { CsrUpload.call(stale, data: material, identity: csr_identity) }
    assert_raises(Certificates::Error) { CsrWorkflow.reveal(stale, identity: csr_identity, confirmed: true) }
    assert_raises(Certificates::Error) { CsrWorkflow.delete(stale, identity: csr_identity, confirmed: true) }
    assert_empty csr.csr_certificates
  end
end
