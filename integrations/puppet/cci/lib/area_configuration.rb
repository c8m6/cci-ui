# frozen_string_literal: true

require_relative "cci_configuration"

# Stable area identities shared by Rails and standalone tools.
class AreaConfiguration
  ID_PATTERN = /\A[a-z][a-z0-9_]{0,47}\z/
  ROLE_TYPES = %w[reader writer key_exporter auditor csr].freeze

  def self.configuration
    { "areas" => CciConfiguration.current.fetch("areas").transform_values { |area| area.fetch("name") },
      "legacy_paths" => legacy_paths }
  end

  def self.ids = CciConfiguration.current.fetch("areas").keys
  def self.label(id) = CciConfiguration.current.fetch("areas").dig(id, "name") || id.to_s

  def self.legacy_paths
    CciConfiguration.current.fetch("areas").filter_map do |id, area|
      path = area.dig("filesystem", "legacy_path")
      [id, path] if path
    end.to_h
  end

  def self.legacy_area
    return legacy_paths.keys.first if legacy_paths.size == 1

    raise ArgumentError, "Specify an area explicitly when multiple or no filesystem inventories are configured."
  end

  def self.roles = ids.product(ROLE_TYPES).map { |area, role| "#{area}_#{role}" }
end
