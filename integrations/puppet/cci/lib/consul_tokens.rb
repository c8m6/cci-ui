# frozen_string_literal: true

require_relative "area_configuration"

# Resolves ACL credentials independently of area encryption keys. Never reports values.
class ConsulTokens
  def self.mapping(environment = ENV, areas: nil)
    areas ||= AreaConfiguration.ids if environment["CCI_AREAS"]
    tokens = AreaConfiguration.parse_object(environment.fetch("CCI_CONSUL_TOKENS", "{}"), "CCI_CONSUL_TOKENS")
    unless tokens.all? do |area, token|
      AreaConfiguration::ID_PATTERN.match?(area) && (!areas || areas.include?(area)) &&
      token.is_a?(String) && !token.empty? && token.match?(/\A[^\s\p{Cntrl}]+\z/)
    end
      raise ArgumentError, "CCI_CONSUL_TOKENS must map configured area IDs to nonempty token strings without whitespace."
    end

    tokens
  end

  def self.resolve(area, fallback: ENV.fetch("CONSUL_TOKEN", ""))
    raise ArgumentError, "Invalid Consul area." unless area.is_a?(String) && AreaConfiguration::ID_PATTERN.match?(area)
    raise ArgumentError, "Unknown Consul area." if ENV["CCI_AREAS"] && !AreaConfiguration.ids.include?(area)

    mapping.fetch(area, fallback)
  end
end
