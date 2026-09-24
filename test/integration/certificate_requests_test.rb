# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class CertificateRequestsTest < ActionDispatch::IntegrationTest
  include CsrFixtures

  test "CSR-only identity creates downloads reveals uploads and sees separate lists" do
    post local_login_path, params: { identity: "zone_a_csr" }
    assert_redirected_to certificate_requests_path
    get new_certificate_request_path
    assert_response :success
    post certificate_requests_path(format: :json), params: { csr: csr_input }
    assert_response :created
    csr = CertificateRequest.find(response.parsed_body.fetch("id"))
    password = CsrSecrets.decrypt(csr, "revoke")
    get certificate_requests_path
    assert_response :success
    assert_includes response.body, csr.common_name
    get certificate_request_path(csr)
    assert_response :success
    refute_includes response.body, password
    refute_includes response.body, csr.encrypted_private_key
    get certificate_request_path(csr, format: :json)
    assert_response :success
    refute_includes response.body, "encrypted"
    post reveal_certificate_request_path(csr, format: :json)
    assert_response :unprocessable_content
    post reveal_certificate_request_path(csr, format: :json), params: { confirm_reveal: "1" }
    assert_response :success
    assert_equal password, response.parsed_body["revoke_password"]
    assert_includes response.headers["Cache-Control"], "no-store"
    post reveal_certificate_request_path(csr), params: { confirm_reveal: "1" }
    assert_response :success
    assert_select "[data-controller='csr-secret']"
    get download_certificate_request_path(csr)
    assert_equal csr.csr_pem, response.body
    post upload_certificate_request_path(csr, format: :json), params: { pem: issued_for(csr).to_pem }
    assert_response :success
    assert_equal "published", response.parsed_body["state"]
    get certificate_requests_path(format: :json)
    assert_empty response.parsed_body["open"]
    assert_equal 1, response.parsed_body["issued"].size
  end

  test "writer reader exporter and auditor cannot access CSR routes or secrets" do
    csr = create_csr
    %w[zone_a_writer zone_a_reader zone_a_exporter zone_a_auditor].each do |role|
      post local_login_path, params: { identity: role }
      get certificate_requests_path(format: :json)
      assert_response :forbidden
      get new_certificate_request_path
      assert_response :forbidden
      get certificate_request_path(csr, format: :json)
      assert_response :forbidden
      get download_certificate_request_path(csr)
      assert_response :forbidden
      post certificate_requests_path(format: :json), params: { csr: csr_input }
      assert_response :forbidden
      %i[reveal upload issuers publish].each do |action|
        post public_send("#{action}_certificate_request_path", csr, format: :json), params: { confirm_reveal: "1" }
        assert_response :forbidden
      end
    end
  end

  test "CSR access is scoped to its area including direct mutations" do
    csr = create_csr(area: "zone_b")
    post local_login_path, params: { identity: "zone_a_csr" }
    get certificate_requests_path(format: :json)
    assert_empty response.parsed_body["open"]
    get certificate_request_path(csr)
    assert_response :not_found
    %i[reveal upload issuers publish].each do |action|
      post public_send("#{action}_certificate_request_path", csr, format: :json)
      assert_response :not_found
    end
    assert_no_difference "CertificateRequest.count" do
      post certificate_requests_path(format: :json), params: { csr: csr_input.merge("area" => "zone_b") }
      assert_response :unprocessable_content
    end
  end

  test "existing sessions can create and reveal during Consul outage and upload reports pending" do
    post local_login_path, params: { identity: "zone_a_csr" }
    original = ConsulStore.method(:client)
    connection = original.call
    connection.define_singleton_method(:get) { |*| raise ConsulConnection::Error, "offline" }
    ConsulStore.define_singleton_method(:client) { connection }
    post certificate_requests_path(format: :json), params: { csr: csr_input }
    assert_response :created
    csr = CertificateRequest.find(response.parsed_body.fetch("id"))
    get certificate_request_path(csr)
    assert_response :success
    post reveal_certificate_request_path(csr, format: :json), params: { confirm_reveal: "1" }
    assert_response :success
    post upload_certificate_request_path(csr, format: :json), params: { pem: issued_for(csr).to_pem }
    assert_response :accepted
    assert_equal "failed", response.parsed_body["state"]
  ensure
    ConsulStore.define_singleton_method(:client, original) if original
  end
end
