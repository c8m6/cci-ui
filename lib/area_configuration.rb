require "json"

# Shared by Rails and the local setup script; contains no framework dependencies.
class AreaConfiguration
  ID_PATTERN = /\A[a-z][a-z0-9_]{0,47}\z/
  ROLE_TYPES = %w[reader writer key_exporter auditor].freeze

  def self.load_env(environment = ENV)
    areas = parse_object(environment["CCI_AREAS"], "CCI_AREAS")
    unless areas.any? && areas.all? { |id, label| ID_PATTERN.match?(id) && label.is_a?(String) && !label.strip.empty? && label.length <= 100 }
      raise ArgumentError, "CCI_AREAS muss gültige Bereichs-IDs (a-z, 0-9, Unterstrich; maximal 48 Zeichen) auf nichtleere Anzeigenamen abbilden."
    end
    paths = parse_object(environment.fetch("CCI_LEGACY_PATHS", "{}"), "CCI_LEGACY_PATHS")
    unless paths.all? { |id, path| areas.key?(id) && path.is_a?(String) && path.start_with?("/") && !path.include?("\0") }
      raise ArgumentError, "CCI_LEGACY_PATHS muss konfigurierte Bereiche auf absolute Verzeichnispfade abbilden."
    end
    { "areas" => areas, "legacy_paths" => paths }
  end

  def self.parse_object(value, variable)
    object = JSON.parse(value.to_s)
    raise ArgumentError unless object.is_a?(Hash)
    object
  rescue JSON::ParserError, ArgumentError
    raise ArgumentError, "#{variable} muss ein gültiges JSON-Objekt enthalten."
  end

  def self.configuration = @configuration ||= load_env
  def self.ids = configuration.fetch("areas").keys
  def self.label(id) = configuration.fetch("areas").fetch(id, id.to_s)
  def self.legacy_paths = configuration.fetch("legacy_paths")
  def self.legacy_area
    return legacy_paths.keys.first if legacy_paths.size == 1
    raise ArgumentError, "Bei mehreren oder keinen Dateibeständen muss der Bereich ausdrücklich angegeben werden."
  end
  def self.roles = ids.product(ROLE_TYPES).map { |area, role| "#{area}_#{role}" }
  def self.key_variable(id)
    raise ArgumentError, "Unbekannter Bereich." unless ids.include?(id)
    "#{id.upcase}_KEY"
  end
end
