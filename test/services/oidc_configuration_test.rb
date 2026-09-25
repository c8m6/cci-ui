# frozen_string_literal: true

require "test_helper"

class OidcConfigurationTest < ActiveSupport::TestCase
  test "role mapping accepts strings and arrays of strings" do
    mapping = OidcConfiguration.load_role_mapping(
      "OIDC_ROLE_MAP" => '{"group-a":"zone_a_reader","group-b":["zone_a_writer","zone_b_reader"]}'
    )

    assert_equal "zone_a_reader", mapping.fetch("group-a")
    assert_equal %w[zone_a_writer zone_b_reader], mapping.fetch("group-b")
    assert_equal({}, OidcConfiguration.load_role_mapping({}))
  end

  test "role mapping rejects invalid JSON shapes without exposing their contents" do
    invalid_values = ["private-invalid-json", "[]", '{"group":{"private":"value"}}', '{"group":[1]}']

    invalid_values.each do |value|
      error = assert_raises(ArgumentError) do
        OidcConfiguration.load_role_mapping("OIDC_ROLE_MAP" => value)
      end
      assert_equal(
        "OIDC_ROLE_MAP must contain a valid JSON object mapping claim names to role strings or arrays of role strings.",
        error.message
      )
      assert_not_includes error.message, value
    end
  end
end
