require "test_helper"

class AreaConfigurationValidationTest < ActiveSupport::TestCase
  test "indexing retains records even if the system clock moves backwards" do
    record = store(issue.first)
    test_case = self
    earlier = 1.minute.ago
    indexer = CatalogIndexer.new
    indexer.define_singleton_method(:upsert) do |cert, attrs|
      test_case.travel_to(earlier) { super(cert, attrs) }
    end
    indexer.consul
    assert Certificate.exists?(record.id)
    assert_in_delta earlier.to_f, record.reload.indexed_at.to_f, 1
  end

  test "areas and local inventories load entirely from environment JSON" do
    settings = {
      "CCI_AREAS" => JSON.generate("one" => "Ein frei gewählter Name", "two" => "Two"),
      "CCI_LEGACY_PATHS" => JSON.generate("one" => "/legacy/one", "two" => "/legacy/two"),
      "CCI_AREAS_FILE" => "/nonexistent/no-longer-used.yml",
      "LEGACY_PATH" => "/not-an-application-setting"
    }
    assert_equal({ "areas" => { "one" => "Ein frei gewählter Name", "two" => "Two" },
      "legacy_paths" => { "one" => "/legacy/one", "two" => "/legacy/two" } }, AreaConfiguration.load_env(settings))
    assert_equal({}, AreaConfiguration.load_env(settings.except("CCI_LEGACY_PATHS")).fetch("legacy_paths"))
  end

  test "missing malformed or ambiguous environment values fail without exposing their contents" do
    [nil, "", "not JSON", "null", "[]", "{}", '{"../one":"Name"}', '{"ONE":"Name"}',
      '{"one":" "}', '{"one":7}'].each do |areas|
      error = assert_raises(ArgumentError) { AreaConfiguration.load_env("CCI_AREAS" => areas) }
      assert_includes error.message, "CCI_AREAS"
      assert_not_includes error.message, areas if areas == "not JSON"
    end
    ["", "not JSON", "null", "[]", '{"missing":"/legacy/missing"}', '{"one":"relative"}',
      '{"one":""}', '{"one":123}', JSON.generate("one" => "/bad\0path")].each do |paths|
      error = assert_raises(ArgumentError) do
        AreaConfiguration.load_env("CCI_AREAS" => '{"one":"One"}', "CCI_LEGACY_PATHS" => paths)
      end
      assert_includes error.message, "CCI_LEGACY_PATHS"
    end
  end

  test "parsed areas generate roles and explicit empty mappings disable local inventory" do
    previous = AreaConfiguration.configuration
    settings = AreaConfiguration.load_env("CCI_AREAS" => '{"custom":"Custom Name"}', "CCI_LEGACY_PATHS" => "{}")
    AreaConfiguration.instance_variable_set(:@configuration, settings)
    assert_equal ["custom"], AreaConfiguration.ids
    assert_equal "Custom Name", AreaConfiguration.label("custom")
    assert_includes AreaConfiguration.roles, "custom_writer"
    assert_empty AreaConfiguration.legacy_paths
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end

  test "legacy reassignment retains search metadata in previous areas" do
    Dir.mktmpdir do |directory|
      previous = AreaConfiguration.configuration
      configure_legacy_paths("zone_a" => directory)
      File.write(File.join(directory, "sample.pem"), issue.first.to_pem)
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      record.update!(area: "zone_b", indexed_at: 1.day.ago)
      CatalogIndexer.new.filesystem
      assert_equal %w[zone_a zone_b], Certificate.where(source: "filesystem").order(:area).pluck(:area)
      assert File.exist?(File.join(directory, "sample.pem"))
    ensure
      AreaConfiguration.instance_variable_set(:@configuration, previous)
    end
  end
end
