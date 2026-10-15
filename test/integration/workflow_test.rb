# frozen_string_literal: true

require "test_helper"

class WorkflowTest < ActionDispatch::IntegrationTest
  include CertificateFixtures

  setup do
    clear_consul
    settings["areas"]["zone_a"]["encryption_key"] = Base64.strict_encode64("r" * 32)
    settings["areas"]["zone_b"]["encryption_key"] = Base64.strict_encode64("s" * 32)
    @cert, @key = issue
    @record = store(@cert, key: @key)
    @hidden = store(issue(name: "hidden.zone_b.test").first, area: "zone_b")
  end
  def login(role)
    post local_login_path, params: { identity: role }
    assert_redirected_to root_path
  end

  test "login search details export and area isolation" do
    get certificates_path
    assert_redirected_to login_path
    login("zone_a_reader")
    get certificates_path
    assert_response :success
    assert_includes response.body, "portal.example.test"
    assert_not_includes response.body, "hidden.zone_b.test"
    get certificate_path(@hidden)
    assert_response :not_found
    get certificate_path(@record)
    assert_response :success
    assert_not_includes response.body, "PRIVATE KEY"
    assert_includes response.body, "Externer Client: test-client"
    assert_select "dt", text: "Erstellt durch"
    post export_certificates_path, params: { ids: [@record.id], format_name: "pem" }
    assert_response :see_other
    assert_not_includes response.body, "PRIVATE KEY"
    post export_certificates_path,
      params: { ids: [@record.id], format_name: "pem", include_key: "1", password: "long-password" }
    assert_response :see_other
    post export_certificates_path, params: { ids: [@record.id, @hidden.id], format_name: "pem" }
    assert_response :not_found
    get new_import_path
    assert_response :forbidden
  end

  test "writer can export public material but cannot reveal or export private key material" do
    login("zone_a_writer")
    get certificate_path(@record)
    assert_response :success
    assert_not_includes response.body, "include_key"
    assert_not_includes response.body, "BEGIN PRIVATE KEY"
    assert_difference "AuditEvent.count", 1 do
      post export_certificates_path, params: { ids: [@record.id], format_name: "pem", include_chain: "1" }
      assert_response :success
      assert_includes response.body, "BEGIN CERTIFICATE"
      assert_not_includes response.body, "PRIVATE KEY"
    end
    assert_no_difference "AuditEvent.count" do
      post export_certificates_path,
        params: { ids: [@record.id], format_name: "pem", include_key: "1", password: "long-password" }
      assert_response :see_other
    end
    login("zone_a_exporter")
    get certificate_path(@record)
    assert_response :success
    assert_includes response.body, "include_key"
    assert_difference "AuditEvent.count", 1 do
      post export_certificates_path,
        params: { ids: [@record.id], format_name: "pem", include_key: "1", password: "long-password" }
      assert_response :success
      assert_includes response.body, "BEGIN ENCRYPTED PRIVATE KEY"
    end
  end

  test "writer import preview and commit only to consul" do
    login("zone_a_writer")
    newer, newer_key = issue(name: "new.example.test", serial: 7)
    post imports_path,
      params: { areas: ["zone_a"], pem: newer.to_pem + newer_key.private_to_pem, tags: "Test, Neu",
                certid: "new.example.test" }
    assert_response :success
    assert_includes response.body, "Bereit zum Speichern"
    assert_not_includes response.body, "PRIVATE KEY"
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert Certificate.exists?(common_name: "new.example.test", source: "consul", area: "zone_a")
    imported = Certificate.find_by!(common_name: "new.example.test")
    assert_equal "cci-ui", imported.client
    assert_equal "Zone A · Writer", imported.created_by
    get certificate_path(imported)
    assert_response :success
    assert_includes response.body, "CCI-UI (Upload)"
    assert_includes response.body, "Zone A · Writer"
    post imports_path, params: { token: token }
    assert_response :see_other
    post imports_path, params: { areas: ["zone_b"], pem: newer.to_pem }
    assert_response :see_other
  end

  test "preview cannot be committed by another session" do
    login("zone_a_writer")
    post imports_path, params: { areas: ["zone_a"], pem: issue(serial: 4).first.to_pem }
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    delete logout_path
    login("zone_a_writer")
    post imports_path, params: { token: token }
    assert_response :see_other
    assert_equal 2, Certificate.count
  end

  test "imports reject multiple target areas even with all writer roles" do
    login("all:writer")
    post imports_path, params: { areas: %w[zone_a zone_b], pem: @cert.to_pem, certid: "both" }
    assert_response :see_other
    assert_equal 0, ImportDraft.count
    assert_not Certificate.exists?(certid: "both")
    %w[zone_a zone_b].each do |area|
      post imports_path, params: { areas: [area], pem: @cert.to_pem + @key.private_to_pem, certid: "independent" }
      assert_response :success
      token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
      post imports_path, params: { token: token }
      assert_redirected_to root_path
    end
    assert_equal %w[zone_a zone_b], Certificate.where(certid: "independent").order(:area).pluck(:area)
  end

  test "reader sees actual CertID identity and linked chain but no export controls or raw PEM" do
    root, root_key = issue(name: "Root CA", ca: true)
    parent = store(root, certid: "root")
    leaf, = issue(issuer: root, issuer_key: root_key, name: "chain.example.test")
    record = store(leaf, chain: [root], certid: "chain")
    login("zone_a_reader")
    get certificate_path(record)
    assert_response :success
    assert_select "a[href=?]", certificate_path(parent)
    assert_equal({ "certid" => "chain", "area" => "zone_a" }, YAML.safe_load(css_select("pre").last.text))
    assert_not_includes response.body, "cci::certificates"
    assert_not_includes response.body, "Zertifikat herunterladen"
    assert_not_includes response.body, "BEGIN CERTIFICATE"
    get certificates_path
    assert_includes response.body, "Puppet-CertID"
    assert_not_includes response.body, "Auswahl exportieren"
  end
end
