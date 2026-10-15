# frozen_string_literal: true

require "json"
require_relative "cci_configuration"

# Interprets YAML inventory settings and builds a properly escaped default PQL query.
class PuppetdbConfiguration
  def self.enabled?(configuration = CciConfiguration.current.fetch("puppetdb")) = configuration.fetch("enabled", false)

  attr_reader :fact_name, :query, :fingerprint_field, :fingerprint_algorithm

  def fingerprint_column = fingerprint_algorithm == "sha1" ? :sha1_fingerprint : :fingerprint
  def fingerprint_length = fingerprint_algorithm == "sha1" ? 40 : 64
  def fingerprint_label = fingerprint_algorithm == "sha1" ? "SHA-1" : "SHA-256"

  def initialize(configuration = CciConfiguration.current.fetch("puppetdb"))
    inventory = configuration.fetch("inventory", {})
    @fingerprint_algorithm = inventory.fetch("fingerprint_algorithm", "sha256").strip.downcase.delete("-")
    unless %w[sha1 sha256].include?(@fingerprint_algorithm)
      raise PuppetdbConnection::Error, "puppetdb.inventory.fingerprint_algorithm must be sha256 or sha1."
    end

    @fact_name = inventory.fetch("fact_name", "certificates")
    raise PuppetdbConnection::Error, "puppetdb.inventory.fact_name must not be empty." if @fact_name.strip.empty?

    @fingerprint_field = inventory.fetch("fingerprint_field", "fingerprint")
    raise PuppetdbConnection::Error, "puppetdb.inventory.fingerprint_field must not be empty." if @fingerprint_field.strip.empty?

    @query = inventory.fetch("query", "")
    return unless @query.strip.empty?

    # PQL string literals need quotes and JSON escaping, including embedded
    # quotes and backslashes in configurable fact names. Plain interpolation
    # would treat a normal fact name as a field and could alter the query.
    @query = "inventory[certname,facts]{ certname in fact_contents[certname]{ name = #{JSON.generate(@fact_name)} } }"
  end
end
