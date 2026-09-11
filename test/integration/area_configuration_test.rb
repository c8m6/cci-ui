require "test_helper"

class AreaConfigurationTest < ActionDispatch::IntegrationTest
  test "a configured zone supports import key export audit and Puppet without code changes" do
    get login_path
    assert_response :success
    assert_select "option[value=zone_b_writer]", text: "Zone B · Writer"
    assert_select "option[value='all:auditor']", text: "Alle Bereiche · Auditor"
    post local_login_path, params: { identity: "zone_b_keys" }
    get new_import_path
    assert_response :success
    assert_select 'input[name="areas[]"]', count: 1
    assert_select 'input[name="areas[]"][value=zone_b]'
    assert_includes response.body, "Zone B"
    cert, key = issue(name: "new-area.test")
    post imports_path, params: { areas: ["zone_b"], pem: cert.to_pem + key.private_to_pem, lookup: "new-area" }
    assert_response :success
    assert_includes response.body, "Zone B"
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    record = Certificate.find_by!(area: "zone_b", lookup: "new-area")
    get certificate_path(record)
    assert_response :success
    assert_select ".area-pill", text: "Zone B"
    post export_certificates_path, params: { ids: [record.id], format_name: "pem", include_key: "1", password: "new-area-password" }
    assert_response :success
    assert_includes response.body, "ENCRYPTED PRIVATE KEY"
    client = CciClient.new(url: ENV.fetch("CONSUL_URL"), prefix: ConsulStore.namespace, keys: { "zone_b" => ENV.fetch("ZONE_B_KEY") })
    assert_equal cert.to_pem, client.fetch(area: "zone_b", lookup: "new-area")
    assert cert.check_private_key(OpenSSL::PKey.read(client.fetch(area: "zone_b", lookup: "new-area", field: "private_key")))
    post local_login_path, params: { identity: "zone_b_auditor" }
    get audit_events_path
    assert_response :success
    assert_includes response.body, "Zone B"
    assert_includes response.body, "new-area.test"
    assert_includes response.body, "Zertifikate mit privaten Schlüsseln exportiert"
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path
    assert_not_includes response.body, "new-area.test"
    post local_login_path, params: { identity: "zone_a_writer" }
    get certificate_path(record)
    assert_response :not_found
  end

  test "configured names are used in all area selectors" do
    post local_login_path, params: { identity: "all:writer" }
    get root_path
    AreaConfiguration.ids.each do |area|
      assert_select "select[name=area] option[value=?]", area, text: AreaConfiguration.label(area)
    end
    get new_import_path
    assert_select 'input[name="areas[]"]', count: 2
    assert_equal [], Identity.new(name: "unknown", roles: %w[missing_writer missing_auditor]).roles
    assert_raises(Certificates::Error) { ConsulStore.prefix("../other") }
    post local_login_path, params: { identity: "missing_writer" }
    assert_response :unprocessable_entity
  end
end
