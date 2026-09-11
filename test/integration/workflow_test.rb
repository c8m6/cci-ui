require "test_helper"

class WorkflowTest < ActionDispatch::IntegrationTest
  include CertificateFixtures
  setup do
    clear_consul
    ENV["ZONE_A_KEY"] = Base64.strict_encode64("r" * 32)
    ENV["ZONE_B_KEY"] = Base64.strict_encode64("s" * 32)
    @cert, @key = issue
    @record = store(@cert, key: @key)
    @hidden = store(issue(name: "hidden.zone_b.test").first, area: "zone_b")
  end
  def login(role)
    post local_login_path, params: { identity: role }
    assert_redirected_to root_path
  end

  test "login search details export and area isolation" do
    get root_path
    assert_redirected_to login_path
    login("zone_a_reader")
    get root_path
    assert_response :success
    assert_includes response.body, "portal.example.test"
    assert_not_includes response.body, "hidden.zone_b.test"
    get certificate_path(@hidden)
    assert_response :not_found
    get certificate_path(@record)
    assert_response :success
    assert_not_includes response.body, "PRIVATE KEY"
    post export_certificates_path, params: { ids: [@record.id], format_name: "pem" }
    assert_response :see_other
    assert_not_includes response.body, "PRIVATE KEY"
    post export_certificates_path, params: { ids: [@record.id], format_name: "pem", include_key: "1", password: "long-password" }
    assert_response :see_other
    post export_certificates_path, params: { ids: [@record.id, @hidden.id], format_name: "pem" }
    assert_response :not_found
    get new_import_path
    assert_response :forbidden
  end

  test "writer import preview and commit only to consul" do
    login("zone_a_writer")
    newer, newer_key = issue(name: "new.example.test", serial: 7)
    post imports_path, params: { areas: ["zone_a"], pem: newer.to_pem + newer_key.private_to_pem, tags: "Test, Neu", lookup: "new.example.test" }
    assert_response :success
    assert_includes response.body, "Bereit zum Speichern"
    assert_not_includes response.body, "PRIVATE KEY"
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert Certificate.exists?(common_name: "new.example.test", source: "consul", area: "zone_a")
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

  test "upload to both areas requires both writer roles" do
    login("zone_a_writer")
    post imports_path, params: { areas: %w[zone_a zone_b], pem: @cert.to_pem, lookup: "both" }
    assert_response :see_other
    assert_equal 0, ImportDraft.count
    login("all:writer")
    post imports_path, params: { areas: %w[zone_a zone_b], pem: @cert.to_pem + @key.private_to_pem, lookup: "both" }
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert_equal %w[zone_a zone_b], Certificate.where(lookup: "both").order(:area).pluck(:area)
    zone_a = Certificate.find_by!(lookup: "both", area: "zone_a")
    zone_b = Certificate.find_by!(lookup: "both", area: "zone_b")
    assert_not_equal zone_a.source_id, zone_b.source_id
    assert CertificateMaterial.load(zone_b, private_key: true)[:certificate].check_private_key(@key)
  end

  test "reader sees Hiera and linked chain but no export controls or raw PEM" do
    root, root_key = issue(name: "Root CA", ca: true)
    parent = store(root, lookup: "root")
    leaf, = issue(issuer: root, issuer_key: root_key, name: "chain.example.test")
    record = store(leaf, chain: [root], lookup: "chain")
    login("zone_a_reader")
    get certificate_path(record)
    assert_response :success
    assert_select "a[href=?]", certificate_path(parent)
    assert_includes response.body, "cci::certificates"
    assert_not_includes response.body, "Zertifikat herunterladen"
    assert_not_includes response.body, "BEGIN CERTIFICATE"
    get root_path
    assert_includes response.body, "Puppet-Lookup"
    assert_not_includes response.body, "Auswahl exportieren"
  end
end
