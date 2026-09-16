require "json"

class PuppetdbConfiguration
  def self.enabled?(environment = ENV)
    case environment.fetch("PUPPETDB_ENABLED", "false").strip.downcase
    when "true", "1" then true
    when "false", "0", "" then false
    else raise PuppetdbConnection::Error, "PUPPETDB_ENABLED muss true oder false sein."
    end
  end

  attr_reader :fact_name, :query, :fingerprint_field, :fingerprint_algorithm

  def fingerprint_column = fingerprint_algorithm == "sha1" ? :sha1_fingerprint : :fingerprint
  def fingerprint_length = fingerprint_algorithm == "sha1" ? 40 : 64
  def fingerprint_label = fingerprint_algorithm == "sha1" ? "SHA-1" : "SHA-256"

  def initialize(environment = ENV)
    @fingerprint_algorithm = environment.fetch("PUPPETDB_FINGERPRINT_ALGORITHM", "sha256").strip.downcase.delete("-")
    unless %w[sha1 sha256].include?(@fingerprint_algorithm)
      raise PuppetdbConnection::Error, "PUPPETDB_FINGERPRINT_ALGORITHM muss sha256 oder sha1 sein."
    end
    @fact_name = environment.fetch("PUPPETDB_FACT_NAME", "certificates")
    if @fact_name.strip.empty?
      raise PuppetdbConnection::Error, "PUPPETDB_FACT_NAME darf nicht leer sein."
    end
    @fingerprint_field = environment.fetch("PUPPETDB_FINGERPRINT_FIELD", "fingerprint")
    if @fingerprint_field.strip.empty?
      raise PuppetdbConnection::Error, "PUPPETDB_FINGERPRINT_FIELD darf nicht leer sein."
    end
    @query = environment.fetch("PUPPETDB_QUERY", "")
    if @query.strip.empty?
      @query = "inventory[certname,facts]{ certname in fact_contents[certname]{ name = #{JSON.generate(@fact_name)} } }"
    end
  end
end
