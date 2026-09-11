require "yaml"

# Shared by Rails and the local setup script; contains no framework dependencies.
class AreaConfiguration
  ID_PATTERN = /\A[a-z][a-z0-9_]{0,47}\z/
  ROLE_TYPES = %w[reader writer key_exporter auditor].freeze

  def self.path
    ENV.fetch("CCI_AREAS_FILE", File.expand_path("../config/areas.yml", __dir__))
  end

  def self.load_file(path)
    config = YAML.safe_load_file(path)
    areas = config.is_a?(Hash) && config["areas"]
    unless areas.is_a?(Hash) && areas.any? && areas.all? { |id, label| id.is_a?(String) && ID_PATTERN.match?(id) && label.is_a?(String) && !label.strip.empty? && label.length <= 100 }
      raise ArgumentError, "Bereichskonfiguration: areas muss eindeutige IDs (a-z, 0-9, Unterstrich; maximal 48 Zeichen) auf Anzeigenamen abbilden."
    end
    unless areas.key?(config["legacy_area"])
      raise ArgumentError, "Bereichskonfiguration: legacy_area muss einen konfigurierten Bereich nennen."
    end
    config
  rescue Psych::Exception, SystemCallError
    raise ArgumentError, "Bereichskonfiguration konnte nicht gelesen werden: #{path}"
  end

  def self.configuration = @configuration ||= load_file(path)
  def self.ids = configuration.fetch("areas").keys
  def self.label(id) = configuration.fetch("areas").fetch(id, id.to_s)
  def self.legacy_area = configuration.fetch("legacy_area")
  def self.roles = ids.product(ROLE_TYPES).map { |area, role| "#{area}_#{role}" }
  def self.key_variable(id)
    raise ArgumentError, "Unbekannter Bereich." unless ids.include?(id)
    "#{id.upcase}_KEY"
  end
end
