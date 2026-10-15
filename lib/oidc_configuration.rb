# frozen_string_literal: true

require_relative "cci_configuration"

# Shared access to startup-validated OIDC settings.
module OidcConfiguration
  DISPLAY_NAME_CLAIMS = %w[preferred_username name email].freeze
  DEFAULT_DISPLAY_NAME_CLAIM = "preferred_username"

  def self.load_role_mapping = CciConfiguration.current.dig("authentication", "oidc", "role_map")
  def self.display_name_claim = CciConfiguration.current.dig("authentication", "oidc", "display_name_claim")
end
