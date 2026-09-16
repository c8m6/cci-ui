require "set"

class PuppetdbInventory
  def self.refresh(environment: ENV, connection: nil)
    return unless PuppetdbConfiguration.enabled?(environment)

    configuration = PuppetdbConfiguration.new(environment)
    connection ||= PuppetdbConnection.new(environment: environment)
    rows = connection.inventory(configuration.query)
    hosts = new(configuration).hosts_by_fingerprint(rows)
    checked_at = Time.current
    column = configuration.fingerprint_column
    # Older retained entries may have no SHA-1 digest until their source is
    # readable again. Keep their previous observations instead of reporting 0.
    records = Certificate.where(area: AreaConfiguration.ids).where.not(column => nil)
    # Validate the entire response before replacing any cached associations.
    # An empty successful result means no hosts in the configured query scope.
    Certificate.transaction do
      records.update_all(puppetdb_hosts: [], puppetdb_checked_at: checked_at, puppetdb_error_at: nil)
      records.distinct.pluck(column).each do |fingerprint|
        next unless hosts.key?(fingerprint)
        records.where(column => fingerprint).update_all(puppetdb_hosts: hosts.fetch(fingerprint).to_a.sort)
      end
    end
  rescue PuppetdbConnection::Error => error
    Certificate.where(area: AreaConfiguration.ids).update_all(puppetdb_error_at: Time.current)
    Rails.logger.warn("PuppetDB-Hostabgleich fehlgeschlagen: #{error.message}")
    raise
  end

  def initialize(configuration)
    @configuration = configuration
  end

  def hosts_by_fingerprint(rows)
    raise PuppetdbConnection::Error, "PuppetDB muss ein Array mit Host-Inventaren liefern." unless rows.is_a?(Array)
    hosts = Hash.new { |hash, key| hash[key] = Set.new }
    rows.each do |row|
      unless row.is_a?(Hash) && row["certname"].is_a?(String) && row["certname"].match?(/\A[^\s\p{Cntrl}]{1,1024}\z/) && row["facts"].is_a?(Hash)
        raise PuppetdbConnection::Error, "PuppetDB-Inventar benötigt certname und facts pro Host."
      end
      facts = row.fetch("facts")
      unless facts.key?(@configuration.fact_name)
        raise PuppetdbConnection::Error, "Das konfigurierte Zertifikats-Fact fehlt im PuppetDB-Inventar. Query und PUPPETDB_FACT_NAME prüfen."
      end
      fingerprints(facts.fetch(@configuration.fact_name)).each do |fingerprint|
        hosts[fingerprint] << row.fetch("certname")
      end
    end
    hosts
  end

  private

  # Accept a fingerprint, a list, or a map keyed by certificate path/name.
  # A certificate object must contain the configured fingerprint field; its
  # remaining metadata is deliberately ignored, as are all unrelated facts.
  def fingerprints(value)
    case value
    when String
      [normalize_fingerprint(value)]
    when Array
      value.flat_map { |entry| fingerprints(entry) }
    when Hash
      if value.key?(@configuration.fingerprint_field)
        [normalize_fingerprint(value.fetch(@configuration.fingerprint_field))]
      else
        value.values.flat_map { |entry| fingerprints(entry) }
      end
    else
      raise PuppetdbConnection::Error, "Ungültiges Zertifikats-Fact: Fingerprints, Listen oder Zertifikatsobjekte erwartet."
    end
  end

  def normalize_fingerprint(value)
    unless value.is_a?(String)
      raise PuppetdbConnection::Error, "Der Zertifikats-Fingerprint muss eine Zeichenkette sein."
    end
    prefix = @configuration.fingerprint_algorithm == "sha1" ? "SHA-?1" : "SHA-?256"
    fingerprint = value.strip.sub(/\A#{prefix}(?:\s+Fingerprint)?\s*[=:]\s*/i, "").delete(":").downcase
    unless fingerprint.match?(/\A[0-9a-f]{#{@configuration.fingerprint_length}}\z/)
      raise PuppetdbConnection::Error, "Das Zertifikats-Fact benötigt #{@configuration.fingerprint_label}-Fingerprints mit #{@configuration.fingerprint_length} Hex-Zeichen."
    end
    fingerprint
  end
end
