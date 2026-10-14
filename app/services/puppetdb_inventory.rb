# frozen_string_literal: true

# Validates complete host inventories before replacing fingerprint-to-host associations.
class PuppetdbInventory
  def self.refresh(environment: ENV, connection: nil)
    return unless PuppetdbConfiguration.enabled?(environment)

    configuration = PuppetdbConfiguration.new(environment)
    connection ||= PuppetdbConnection.new(environment: environment)
    rows = connection.inventory(configuration.query)
    inventory = new(configuration)
    hosts = inventory.hosts_by_fingerprint(rows)
    checked_at = Time.current
    column = configuration.fingerprint_column
    # Older retained entries may have no SHA-1 digest until their source is
    # readable again. Keep their previous observations instead of reporting 0.
    records = Certificate.retained.where(area: AreaConfiguration.ids).where.not(column => nil)
    differences = records.pluck(column, :puppetdb_hosts).count do |fingerprint, previous_hosts|
      previous_hosts.to_a.sort != hosts.fetch(fingerprint, []).to_a.sort
    end
    # Validate the entire response before replacing any cached associations.
    # An empty successful result means no hosts in the configured query scope.
    inventory.replace_associations(records, column, hosts, checked_at)
    result = if rows.empty?
               "no_data"
             elsif differences.zero?
               "no_difference"
             else
               "updated"
             end
    message = rows.empty? ? "PuppetDB returned no matching data" : "PuppetDB comparison completed"
    OperationalLog.debug(logger: "cci.puppetdb", message: message, system: "puppetdb",
      operation: "compare_inventory", http_status: connection.respond_to?(:last_http_status) ? connection.last_http_status : nil,
      resource_count: rows.size, diff_count: differences, result: result)
  rescue PuppetdbConnection::Error => e
    Certificate.retained.where(area: AreaConfiguration.ids).update_all(puppetdb_error_at: Time.current)
    OperationalLog.failure(logger: "cci.puppetdb", message: "PuppetDB host synchronisation failed",
      error: e, level: :warn, system: "puppetdb", operation: "compare_inventory", result: "failed")
    raise
  end

  def initialize(configuration)
    @configuration = configuration
    @paths = {}
  end

  def replace_associations(records, column, hosts, checked_at)
    Certificate.transaction do
      records.update_all(puppetdb_hosts: [], puppetdb_paths: {}, puppetdb_checked_at: checked_at, puppetdb_error_at: nil)
      records.distinct.pluck(column).each do |fingerprint|
        next unless hosts.key?(fingerprint)

        records.where(column => fingerprint).update_all(puppetdb_hosts: hosts.fetch(fingerprint).to_a.sort,
          puppetdb_paths: paths.fetch(fingerprint, {}))
      end
    end
  end

  attr_reader :paths

  def hosts_by_fingerprint(rows)
    raise PuppetdbConnection::Error, "PuppetDB must return an array of host inventories." unless rows.is_a?(Array)

    @paths = {}
    hosts = Hash.new { |hash, key| hash[key] = Set.new }
    rows.each do |row|
      unless row.is_a?(Hash) && row["certname"].is_a?(String) && row["certname"].match?(/\A[^\s\p{Cntrl}]{1,1024}\z/) &&
             row["facts"].is_a?(Hash)
        raise PuppetdbConnection::Error, "PuppetDB inventory requires certname and facts for each host."
      end

      facts = row.fetch("facts")
      unless facts.key?(@configuration.fact_name)
        raise PuppetdbConnection::Error,
          "The configured certificate fact is missing from the PuppetDB inventory. Check the query and PUPPETDB_FACT_NAME."
      end

      fingerprints(facts.fetch(@configuration.fact_name)).each do |fingerprint, path|
        hosts[fingerprint] << row.fetch("certname")
        next unless path

        @paths[fingerprint] ||= {}
        (@paths[fingerprint][row.fetch("certname")] ||= []) << path
        @paths[fingerprint][row.fetch("certname")].uniq!
      end
    end
    hosts
  end

  private

  # Accept a fingerprint, a list, or a map keyed by certificate path/name.
  # A certificate object must contain the configured fingerprint field; its
  # optional absolute file path is retained; other metadata and facts are ignored.
  def fingerprints(value, path = nil)
    case value
    when String
      [[normalize_fingerprint(value), safe_path(path)]]
    when Array
      value.flat_map { |entry| fingerprints(entry, path) }
    when Hash
      if value.key?(@configuration.fingerprint_field)
        [[normalize_fingerprint(value.fetch(@configuration.fingerprint_field)), safe_path(value["path"] || value["file"] || path)]]
      else
        value.flat_map { |name, entry| fingerprints(entry, safe_path(name) || path) }
      end
    else
      raise PuppetdbConnection::Error, "Invalid certificate fact: expected fingerprints, lists or certificate objects."
    end
  end

  def safe_path(value)
    value if value.is_a?(String) && value.start_with?("/") && value.length <= 4096 && !value.match?(/\p{Cntrl}/)
  end

  def normalize_fingerprint(value)
    raise PuppetdbConnection::Error, "The certificate fingerprint must be a string." unless value.is_a?(String)

    prefix = @configuration.fingerprint_algorithm == "sha1" ? "SHA-?1" : "SHA-?256"
    fingerprint = value.strip.sub(/\A#{prefix}(?:\s+Fingerprint)?\s*[=:]\s*/i, "").delete(":").downcase
    unless fingerprint.match?(/\A[0-9a-f]{#{@configuration.fingerprint_length}}\z/)
      raise PuppetdbConnection::Error,
        "The certificate fact requires #{@configuration.fingerprint_label} fingerprints " \
        "with #{@configuration.fingerprint_length} hexadecimal characters."
    end

    fingerprint
  end
end
