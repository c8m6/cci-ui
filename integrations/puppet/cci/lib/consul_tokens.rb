# frozen_string_literal: true

require_relative "cci_configuration"

# Resolves one effective credential; transport errors never trigger fallback.
class ConsulTokens
  def self.resolve(area)
    CciConfiguration.current.consul(area).fetch("token")
  end
end
