# frozen_string_literal: true

require "json"

# Parses OIDC environment settings without exposing their contents in errors.
module OidcConfiguration
  def self.load_role_mapping(environment = ENV)
    mapping = JSON.parse(environment.fetch("OIDC_ROLE_MAP", "{}").to_s)
    raise ArgumentError unless mapping.is_a?(Hash)

    valid = mapping.all? do |source, roles|
      source.is_a?(String) &&
        (roles.is_a?(String) || (roles.is_a?(Array) && roles.all?(String)))
    end
    raise ArgumentError unless valid

    mapping
  rescue JSON::ParserError, ArgumentError
    raise ArgumentError,
      "OIDC_ROLE_MAP must contain a valid JSON object mapping claim names to role strings or arrays of role strings."
  end
end
