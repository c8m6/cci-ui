# frozen_string_literal: true

require "test_helper"

class PuppetdbConfigurationTest < ActiveSupport::TestCase
  test "default PQL retains literal quotes backslashes and Unicode in fact names" do
    ["certificates", 'facts" or certname = "other', "path\\fact", "Prüfung"].each do |name|
      configuration = PuppetdbConfiguration.new("PUPPETDB_FACT_NAME" => name)
      literal = configuration.query.delete_prefix("inventory[certname,facts]{ certname in fact_contents[certname]{ name = ")
                             .delete_suffix(" } }")
      assert_equal name, JSON.parse(literal)
    end
  end

  test "explicit PQL is retained unchanged" do
    query = 'inventory[certname,facts]{ certname = "host.example.test" }'
    assert_equal query, PuppetdbConfiguration.new("PUPPETDB_QUERY" => query).query
  end
end
