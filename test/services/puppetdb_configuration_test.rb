# frozen_string_literal: true

require "test_helper"

class PuppetdbConfigurationTest < ActiveSupport::TestCase
  def inventory_settings(values) = PuppetdbConfiguration.new(puppetdb_settings(values))

  test "default PQL retains literal quotes backslashes and Unicode in fact names" do
    ["certificates", 'facts" or certname = "other', "path\\fact", "Prüfung"].each do |name|
      configuration = inventory_settings("inventory.fact_name" => name)
      literal = configuration.query.delete_prefix("inventory[certname,facts]{ certname in fact_contents[certname]{ name = ")
                             .delete_suffix(" } }")
      assert_equal name, JSON.parse(literal)
    end
  end

  test "explicit PQL is retained unchanged" do
    query = 'inventory[certname,facts]{ certname = "host.example.test" }'
    assert_equal query, inventory_settings("inventory.query" => query).query
  end
end
