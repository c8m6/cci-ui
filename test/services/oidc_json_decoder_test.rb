# frozen_string_literal: true

require "test_helper"
require "faraday"
require "oidc_json_decoder"

class OidcJsonDecoderTest < ActiveSupport::TestCase
  def connection(body, options = {})
    Faraday.new do |http|
      http.response :json
      http.builder.swap(Faraday::Response::Json, Faraday::Response::Json,
        parser_options: { decoder: [OidcJsonDecoder, :parse] }.merge(options))
      http.adapter :test do |stubs|
        stubs.get("/synthetic-oidc-response") { [200, { "Content-Type" => "application/json" }, body] }
      end
    end
  end

  def test_valid_discovery_token_keys_and_userinfo_responses
    [
      { "issuer" => "https://auth.example.test/realms/cci", "authorization_endpoint" => "https://auth.example.test/authorize" },
      { "access_token" => "synthetic-token", "token_type" => "Bearer" },
      { "keys" => [] },
      { "sub" => "synthetic-user", "name" => "Example User" }
    ].each do |expected|
      response = connection(JSON.generate(expected)).get("/synthetic-oidc-response")
      assert_equal expected, response.body
    end
  end

  def test_parser_options_are_forwarded
    response = connection('{"issuer":"example"}', symbolize_names: true).get("/synthetic-oidc-response")
    assert_equal({ issuer: "example" }, response.body)
  end

  def test_invalid_json_remains_a_parse_failure
    error = assert_raises(Faraday::ParsingError) do
      connection("invalid JSON").get("/synthetic-oidc-response")
    end
    assert_kind_of JSON::ParserError, error.cause
  end
end
