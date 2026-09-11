require "test_helper"

class AreaConfigurationValidationTest < ActiveSupport::TestCase
  test "index pruning retains seen records even if the system clock moves backwards" do
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

  test "configuration supports one area and rejects invalid IDs names and legacy mappings" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "areas.yml")
      valid = { "areas" => { "one" => "Ein frei gewählter Name" }, "legacy_area" => "one" }
      File.write(path, valid.to_yaml)
      assert_equal valid, AreaConfiguration.load_file(path)
      [
        { "areas" => {}, "legacy_area" => "one" },
        { "areas" => { "../one" => "Name" }, "legacy_area" => "../one" },
        { "areas" => { "ONE" => "Name" }, "legacy_area" => "ONE" },
        { "areas" => { "one" => " " }, "legacy_area" => "one" },
        { "areas" => { "one" => "Name" }, "legacy_area" => "missing" }
      ].each do |invalid|
        File.write(path, invalid.to_yaml)
        assert_raises(ArgumentError) { AreaConfiguration.load_file(path) }
      end
    end
  end

  test "legacy reassignment removes stale search metadata from previous areas" do
    Dir.mktmpdir do |directory|
      previous = ENV["LEGACY_PATH"]
      ENV["LEGACY_PATH"] = directory
      File.write(File.join(directory, "sample.pem"), issue.first.to_pem)
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      record.update!(area: "zone_b", indexed_at: 1.day.ago)
      CatalogIndexer.new.filesystem
      assert_equal [AreaConfiguration.legacy_area], Certificate.where(source: "filesystem").pluck(:area)
      assert File.exist?(File.join(directory, "sample.pem"))
    ensure
      ENV["LEGACY_PATH"] = previous
    end
  end
end
