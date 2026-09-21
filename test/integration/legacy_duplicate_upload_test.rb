require "test_helper"

class LegacyDuplicateUploadTest < ActionDispatch::IntegrationTest
  setup do
    @previous_legacy = AreaConfiguration.configuration
    @directory = Dir.mktmpdir("cci-upload-inventory-")
    configure_legacy_paths("zone_a" => @directory)
    @cert, @key = issue
    @path = File.join(@directory, "legacy.pem")
    post local_login_path, params: { identity: "zone_b_writer" }
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_legacy)
    FileUtils.remove_entry(@directory)
  end

  def upload(pem: @cert.to_pem, **options)
    post imports_path, params: { areas: ["zone_b"], pem: pem, certid: "different-certid" }.merge(options)
  end

  test "unindexed disk certificate blocks upload across areas and under another certid" do
    File.write(@path, @cert.to_pem.gsub("\n", "\r\n"))
    upload(pem: @cert.to_pem + @key.private_to_pem)
    assert_response :see_other
    follow_redirect!
    assert_includes response.body, "bereits im Dateibestand vorhanden"
    assert_not_includes response.body, @path
    assert_empty ImportDraft.all
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/areas/")
  end

  test "DER file upload is checked by certificate identity" do
    File.write(@path, @cert.to_pem)
    der = File.join(@directory, "upload.der")
    File.binwrite(der, @cert.to_der)
    file = Rack::Test::UploadedFile.new(der, "application/pkix-cert", true)
    upload(pem: "", files: [file])
    assert_response :see_other
    assert_empty ImportDraft.all
  end

  test "a duplicate in a bundle rejects the entire batch before saving" do
    File.write(@path, @cert.to_pem)
    fresh, = issue(serial: 2)
    upload(pem: fresh.to_pem + @cert.to_pem, certid: "")
    assert_response :see_other
    assert_empty ImportDraft.all
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/areas/")
  end

  test "certificate appearing after preview blocks the entire commit" do
    fresh, = issue(serial: 2)
    upload(pem: fresh.to_pem + @cert.to_pem, certid: "")
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    File.write(@path, @cert.to_pem)
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_response :see_other
    assert_empty Certificate.where(source: "consul")
    assert_empty ConsulStore.client.all("#{ConsulStore.namespace}/areas/")
    assert ImportDraft.exists?(token: token)
  end

  test "deleted disk certificate no longer blocks upload despite stale search index" do
    File.write(@path, @cert.to_pem)
    CatalogIndexer.new.filesystem
    File.delete(@path)
    assert Certificate.exists?(source: "filesystem")
    upload
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert Certificate.exists?(source: "consul", fingerprint: Certificates::Codec.fingerprint(@cert))
  end

  test "same subject with different DER is a renewal and can be uploaded" do
    File.write(@path, @cert.to_pem)
    renewed, = issue(serial: 2)
    upload(pem: renewed.to_pem)
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert Certificate.exists?(source: "consul", fingerprint: Certificates::Codec.fingerprint(renewed))
  end

  test "incomplete inventory blocks preview and commit instead of assuming no duplicates" do
    upload
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    configure_legacy_paths("zone_a" => File.join(@directory, "missing"))
    post imports_path, params: { token: token }
    assert_response :service_unavailable
    assert_empty Certificate.where(source: "consul")
    upload
    assert_response :service_unavailable
    configure_legacy_paths("zone_a" => @directory)
    File.write(@path, "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n")
    upload
    assert_response :see_other
    assert_equal 1, ImportDraft.count
  end
end
