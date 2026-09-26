# frozen_string_literal: true

require "json"

# Parses OIDC environment settings without exposing their contents in errors.
module OidcConfiguration
  DISPLAY_NAME_CLAIMS = %w[preferred_username name email].freeze
  DEFAULT_DISPLAY_NAME_CLAIM = "preferred_username"

  def self.load_role_mapping(environment = ENV)
    raw = environment.fetch("OIDC_ROLE_MAP", "").to_s
    mapping = JSON.parse(raw.strip.empty? ? "{}" : raw)
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

  def self.display_name_claim(environment = ENV)
    claim = environment.fetch("OIDC_DISPLAY_NAME_CLAIM", "").to_s.strip
    claim = DEFAULT_DISPLAY_NAME_CLAIM if claim.empty?
    return claim if DISPLAY_NAME_CLAIMS.include?(claim)

    raise ArgumentError, "OIDC_DISPLAY_NAME_CLAIM must be preferred_username, name or email."
  end
end
