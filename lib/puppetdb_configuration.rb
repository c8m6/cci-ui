# frozen_string_literal: true

require "json"

# Validates environment settings and builds a properly escaped default PQL query.
class PuppetdbConfiguration
  def self.enabled?(environment = ENV)
    case environment.fetch("PUPPETDB_ENABLED", "false").strip.downcase
    when "true", "1" then true
    when "false", "0", "" then false
    else raise PuppetdbConnection::Error, "PUPPETDB_ENABLED must be true or false."
    end
  end

  attr_reader :fact_name, :query, :fingerprint_field, :fingerprint_algorithm

  def fingerprint_column = fingerprint_algorithm == "sha1" ? :sha1_fingerprint : :fingerprint
  def fingerprint_length = fingerprint_algorithm == "sha1" ? 40 : 64
  def fingerprint_label = fingerprint_algorithm == "sha1" ? "SHA-1" : "SHA-256"

  def initialize(environment = ENV)
    @fingerprint_algorithm = environment.fetch("PUPPETDB_FINGERPRINT_ALGORITHM", "sha256").strip.downcase.delete("-")
    unless %w[sha1 sha256].include?(@fingerprint_algorithm)
      raise PuppetdbConnection::Error, "PUPPETDB_FINGERPRINT_ALGORITHM must be sha256 or sha1."
    end

    @fact_name = environment.fetch("PUPPETDB_FACT_NAME", "certificates")
    raise PuppetdbConnection::Error, "PUPPETDB_FACT_NAME must not be empty." if @fact_name.strip.empty?

    @fingerprint_field = environment.fetch("PUPPETDB_FINGERPRINT_FIELD", "fingerprint")
    raise PuppetdbConnection::Error, "PUPPETDB_FINGERPRINT_FIELD must not be empty." if @fingerprint_field.strip.empty?

    @query = environment.fetch("PUPPETDB_QUERY", "")
    return unless @query.strip.empty?

    # PQL string literals need quotes and JSON escaping, including embedded
    # quotes and backslashes in configurable fact names. Plain interpolation
    # would treat a normal fact name as a field and could alter the query.
    @query = "inventory[certname,facts]{ certname in fact_contents[certname]{ name = #{JSON.generate(@fact_name)} } }"
  end
end
