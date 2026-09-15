require "test_helper"

class MultipleLegacySourcesIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @previous_configuration = AreaConfiguration.configuration
    @directory = Dir.mktmpdir("cci-zone-files-")
    @paths = %w[zone_a zone_b].to_h { |area| [area, File.join(@directory, area)] }
    @paths.each_value { |path| Dir.mkdir(path) }
    AreaConfiguration.instance_variable_set(:@configuration,
      @previous_configuration.merge("legacy_paths" => @paths))
    @certificates = {}
    @paths.each do |area, path|
      cert, key = issue(name: "#{area}.example.test")
      @certificates[area] = cert
      File.write(File.join(path, "same.pem"), cert.to_pem)
      File.write(File.join(path, "same.key"), key.private_to_pem)
      File.write(File.join(path, "same.tag"), "_#{area}")
    end
    CatalogIndexer.run
    @records = Certificate.where(source: "filesystem").index_by(&:area)
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_configuration)
    FileUtils.remove_entry(@directory)
  end

  test "UI and exports enforce zone ownership with identical relative paths" do
    post local_login_path, params: { identity: "zone_a_reader" }
    get root_path
    assert_response :success
    assert_includes response.body, "zone_a.example.test"
    assert_not_includes response.body, "zone_b.example.test"
    get certificate_path(@records.fetch("zone_a"))
    assert_response :success
    assert_includes response.body, "_zone_a"
    get certificate_path(@records.fetch("zone_b"))
    assert_response :not_found
    post local_login_path, params: { identity: "zone_b_keys" }
    get certificate_path(@records.fetch("zone_b"))
    assert_response :success
    assert_includes response.body, "_zone_b"
    assert_not_includes response.body, "_zone_a"
    post export_certificates_path, params: { ids: [@records.fetch("zone_b").id], format_name: "pem", include_key: "1", password: "zone-password-long" }
    assert_response :success
    parsed = Certificates::Codec.parse(response.body, password: "zone-password-long")
    assert_equal @certificates.fetch("zone_b").to_der, parsed.certificates.first.to_der
    assert parsed.certificates.first.check_private_key(parsed.keys.first)
    post export_certificates_path, params: { ids: [@records.fetch("zone_a").id], format_name: "pem" }
    assert_response :not_found
  end

  test "upload checks all disk zones even when writer can access only one" do
    post local_login_path, params: { identity: "zone_a_writer" }
    post imports_path, params: { areas: ["zone_a"], pem: @certificates.fetch("zone_b").to_pem, lookup: "new-name" }
    assert_response :see_other
    follow_redirect!
    assert_includes response.body, "bereits im Dateibestand vorhanden"
    assert_not_includes response.body, @paths.fetch("zone_b")
    assert_empty ImportDraft.all
    assert_empty Certificate.where(source: "consul")
  end

  test "commit detects a certificate added to another zone after preview" do
    fresh, = issue(name: "new.example.test")
    post local_login_path, params: { identity: "zone_a_writer" }
    post imports_path, params: { areas: ["zone_a"], pem: fresh.to_pem, lookup: "new-name" }
    assert_response :success
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    File.write(File.join(@paths.fetch("zone_b"), "added.pem"), fresh.to_pem)
    post imports_path, params: { token: token }
    assert_response :see_other
    assert_empty Certificate.where(source: "consul")
  end
end
