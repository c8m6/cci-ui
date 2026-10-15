# frozen_string_literal: true

require_relative "cci_configuration"

# Uses the existing Base64 area keys without changing envelope formats.
class AreaSecrets
  def self.fetch(area)
    CciConfiguration.current.fetch("areas").fetch(area).fetch("encryption_key").to_s
  rescue KeyError
    raise ArgumentError, "Unknown area."
  end
end
