# frozen_string_literal: true

require "json"

# Framework-independent so UI, standalone writers and Puppet use the same keys.
class AreaSecrets
  def self.fetch(area, environment = ENV)
    raise ArgumentError, "Invalid area" unless area.is_a?(String) && area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)

    raw = environment["CCI_AREA_KEYS"]
    keys = raw.nil? || raw.empty? ? {} : JSON.parse(raw)
    unless keys.is_a?(Hash) && keys.all? { |id, key| id.match?(/\A[a-z][a-z0-9_]{0,47}\z/) && key.is_a?(String) }
      raise ArgumentError, "CCI_AREA_KEYS must map area IDs to Base64 key strings"
    end

    keys.fetch(area) { environment.fetch("#{area.upcase}_KEY", "") }
  rescue JSON::ParserError
    raise ArgumentError, "CCI_AREA_KEYS must contain a valid JSON object"
  end
end
