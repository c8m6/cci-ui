# frozen_string_literal: true

require "test_helper"

class AreaConfigurationValidationTest < ActiveSupport::TestCase
  test "Rails JSON decoding remains compatible with keyword options and JSON round trips" do
    assert_equal({ "role" => "writer" }, ActiveSupport::JSON.decode('{"role":"writer"}', symbolize_names: false))
    assert_equal({ "role" => "writer" }, JSON.parse('{"role":"writer"}', symbolize_names: false))

    payload = { "certid" => "host.example.test", "subject" => "CN=Grüße & special", "areas" => ["zone_a"] }
    encoded = ActiveSupport::JSON.encode(payload)
    assert_equal payload, ActiveSupport::JSON.decode(encoded)
    assert_equal payload, JSON.parse(encoded)
  end

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
      configure_legacy_paths(previous.fetch("legacy_paths"))
    end
  end
end
