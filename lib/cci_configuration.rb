# frozen_string_literal: true

require "yaml"
require "base64"
require "uri"

# One immutable, framework-independent configuration snapshot per process.
class CciConfiguration
  class Error < ArgumentError; end

  SECRET = :secret
  SCHEMA = {
    "version" => Integer,
    "server" => { "host" => String, "port" => Integer, "allowed_hosts" => [String], "secret_key_base" => SECRET,
                  "show_error_details" => :boolean, "log_level" => String, "threads" => Integer, "health_token" => SECRET },
    "database" => { "host" => String, "port" => Integer, "name" => String, "username" => String, "password" => SECRET,
                    "sslmode" => String, "sslrootcert" => String, "sslcert" => String, "sslkey" => String },
    "authentication" => { "mode" => String, "oidc" => { "issuer" => String, "client_id" => String,
                                                        "client_secret" => SECRET, "redirect_uri" => String,
                                                        "display_name_claim" => String, "role_map" => :roles } },
    "consul" => { "url" => String, "prefix" => String, "ca_file" => String, "token" => SECRET },
    "areas" => :areas,
    "certificates" => { "expiry_warning_days" => Integer, "reconciliation" => {
      "enabled" => :boolean, "missing_after_scans" => Integer, "max_delete_percent" => Integer
    } },
    "csr" => { "defaults" => { "key_algorithm" => String, "key_size" => Integer, "digest" => String,
                               "country" => String, "state" => String, "locality" => String, "organization" => String,
                               "organizational_unit" => String } },
    "puppetdb" => { "enabled" => :boolean, "url" => String, "inventory" => { "fact_name" => String,
                                                                             "fingerprint_field" => String,
                                                                             "fingerprint_algorithm" => String, "query" => String },
                    "tls" => { "ca_file" => String, "cert_file" => String, "key_file" => String },
                    "authentication" => { "token" => SECRET }, "request" => { "timeout" => Integer, "max_response_bytes" => Integer } },
    "integrations" => { "zabbix" => { "enabled" => :boolean, "token" => SECRET, "certificate_sources" => String },
                        "writer" => { "client_id" => String, "actor" => String, "key_password" => SECRET } },
    "indexer" => { "interval_seconds" => Integer }
  }.freeze
  AREA_SCHEMA = { "name" => String, "encryption_key" => SECRET, "filesystem" => { "legacy_path" => String },
                  "consul" => SCHEMA.fetch("consul") }.freeze
  DEFAULTS = {
    "server" => { "host" => "localhost", "port" => 3000, "allowed_hosts" => ["localhost", "127.0.0.1"],
                  "secret_key_base" => "local-development-only-" * 8, "show_error_details" => false, "log_level" => "info",
                  "threads" => 5, "health_token" => "" },
    "database" => { "host" => "db", "port" => 5432 },
    "authentication" => { "mode" => "oidc", "oidc" => { "display_name_claim" => "preferred_username", "role_map" => {} } },
    "consul" => { "url" => "http://127.0.0.1:8500", "prefix" => "cci", "ca_file" => "", "token" => "" },
    "certificates" => { "expiry_warning_days" => 10, "reconciliation" => {
      "enabled" => true, "missing_after_scans" => 2, "max_delete_percent" => 20
    } },
    "csr" => { "defaults" => { "key_algorithm" => "RSA", "key_size" => 4096, "digest" => "SHA512", "country" => "",
                               "state" => "", "locality" => "", "organization" => "", "organizational_unit" => "" } },
    "puppetdb" => { "enabled" => false, "url" => "", "inventory" => { "fact_name" => "certificates",
                                                                      "fingerprint_field" => "fingerprint",
                                                                      "fingerprint_algorithm" => "sha256", "query" => "" },
                    "tls" => { "ca_file" => "", "cert_file" => "", "key_file" => "" }, "authentication" => { "token" => "" },
                    "request" => { "timeout" => 30, "max_response_bytes" => 52_428_800 } },
    "integrations" => { "zabbix" => { "enabled" => false, "token" => "", "certificate_sources" => "consul" },
                        "writer" => { "client_id" => "puppet", "actor" => "", "key_password" => "" } },
    "indexer" => { "interval_seconds" => 60 }
  }.freeze

  def self.current = @current ||= load_file(ENV.fetch("CCI_CONFIG_FILE", File.expand_path("../config.yml", __dir__)))

  def self.load_file(path, production: ENV["RAILS_ENV"] == "production")
    text = File.read(path)
    validate_nodes!(Psych.parse_stream(text))
    supplied = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
    new(supplied, production: production)
  rescue Psych::Exception, SystemCallError, IOError
    raise Error, "Cannot read configuration YAML; check CCI_CONFIG_FILE, syntax and file permissions.", cause: nil
  end

  def self.validate_nodes!(node)
    raise Error, "Configuration must contain exactly one YAML document." if node.is_a?(Psych::Nodes::Stream) && node.children.size != 1

    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map(&:first)
      raise Error, "Duplicate or invalid YAML keys." unless keys.all?(Psych::Nodes::Scalar) && keys.map(&:value).uniq.size == keys.size
    end
    Array(node.children).each { |child| validate_nodes!(child) } if node.respond_to?(:children)
  end

  def initialize(supplied, production: false)
    validate_types!(supplied, SCHEMA, "configuration")
    @data = merge(DEFAULTS, supplied)
    validate_values!(supplied, production)
    freeze_tree(@data)
    freeze
  end

  def dig(*keys) = @data.dig(*keys)
  def fetch(key) = @data.fetch(key)

  def secrets
    secret_values(@data)
  end

  def consul(area = nil)
    return fetch("consul") unless area

    fetch("consul").merge(fetch("areas").fetch(area).fetch("consul", {}))
  end

  private

  def secret_values(value)
    return [] unless value.is_a?(Hash)

    value.flat_map do |key, item|
      if %w[secret_key_base password client_secret token encryption_key health_token key_password].include?(key)
        item.is_a?(String) && !item.empty? ? [item] : []
      else
        secret_values(item)
      end
    end
  end

  def validate_types!(value, schema, path)
    raise Error, "#{path} has an invalid type." unless value.is_a?(Hash) && (value.keys - schema.keys).empty?

    value.each do |key, item|
      kind = schema.fetch(key)
      name = "#{path}.#{key}"
      case kind
      when Hash then validate_types!(item, kind, name)
      when Array then validate_string_list!(item, name)
      when :secret then value[key] = resolve_secret(item, name)
      when :areas then validate_areas!(item)
      when :roles then validate_roles!(item, name)
      when :boolean
        raise Error, "#{name} must be a boolean." unless [true, false].include?(item)
      else
        raise Error, "#{name} has an invalid type." unless item.is_a?(kind)
      end
    end
  end

  def string_list?(item) = item.is_a?(Array) && item.all?(String)

  def validate_string_list!(item, name)
    raise Error, "#{name} must be a list of strings." unless string_list?(item)
  end

  def resolve_secret(value, path)
    if value.is_a?(Hash) && value.keys == ["file"] && value["file"].is_a?(String)
      file_path!(value["file"], path)
      value = File.binread(value["file"]).sub(/\r?\n\z/, "")
    end
    raise Error, "#{path} must be a string or a file reference." unless value.is_a?(String)
    raise Error, "#{path} must contain a resolved secret." if value.start_with?("ENC[")

    value
  rescue SystemCallError, IOError
    raise Error, "#{path} secret file is missing or unreadable."
  end

  def validate_areas!(areas)
    raise Error, "areas must be a nonempty mapping." unless areas.is_a?(Hash) && areas.any?

    areas.each do |id, area|
      raise Error, "Invalid area ID." unless id.is_a?(String) && id.match?(/\A[a-z][a-z0-9_]{0,47}\z/)

      validate_types!(area, AREA_SCHEMA, "areas.#{id}")
      required!(area, %w[name encryption_key], "areas.#{id}")
      raise Error, "Area display name is too long." if area.fetch("name").size > 100

      key = Base64.strict_decode64(area.fetch("encryption_key"))
      raise Error, "Area encryption keys must encode exactly 32 bytes." unless key.bytesize == 32

      path = area.dig("filesystem", "legacy_path")
      raise Error, "Area legacy_path must be absolute." if path && (!path.start_with?("/") || path.include?("\0"))
    rescue ArgumentError
      raise Error, "Invalid area configuration or Base64 encryption key."
    end
  end

  def validate_roles!(mapping, path)
    valid = mapping.is_a?(Hash) && mapping.all? do |source, roles|
      source.is_a?(String) && (roles.is_a?(String) || (roles.is_a?(Array) && roles.all?(String)))
    end
    raise Error, "#{path} must map claim names to role strings or lists." unless valid
  end

  def validate_values!(supplied, production)
    required!(@data, %w[version areas database], "configuration")
    raise Error, "Unsupported configuration version." unless dig("version") == 1

    required!(fetch("database"), %w[name username password], "database")
    positive!(%w[server port], %w[server threads], %w[database port], %w[certificates expiry_warning_days],
      %w[puppetdb request timeout], %w[puppetdb request max_response_bytes], %w[indexer interval_seconds])
    enum!(%w[authentication mode], %w[oidc local])
    enum!(%w[server log_level], %w[debug info warn error fatal])
    enum!(%w[authentication oidc display_name_claim], %w[preferred_username name email])
    enum!(%w[puppetdb inventory fingerprint_algorithm], %w[sha1 sha256])
    enum!(%w[integrations zabbix certificate_sources], %w[consul filesystem both])
    enum!(%w[database sslmode], %w[disable allow prefer require verify-ca verify-full]) if dig("database", "sslmode")
    %w[sslrootcert sslcert sslkey].each do |key|
      path = dig("database", key)
      file_path!(path, "database.#{key}") if path
    end
    validate_reconciliation!
    validate_csr!
    validate_integrations!(supplied, production)
    targets = dig("authentication", "oidc", "role_map").values.flatten
    roles = fetch("areas").keys.product(%w[reader writer key_exporter auditor csr]).map { |area, role| "#{area}_#{role}" }
    raise Error, "role_map references unknown CCI roles or areas." unless (targets - roles).empty?

    [consul, *fetch("areas").keys.map { |area| consul(area) }].each { |settings| validate_consul!(settings) }
  end

  def validate_consul!(settings)
    url!(settings.fetch("url"), "Consul URL")
    raise Error, "Invalid Consul prefix." unless settings.fetch("prefix").match?(%r{\A[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*\z})

    file_path!(settings["ca_file"], "Consul CA") unless settings["ca_file"].to_s.empty?
    raise Error, "Invalid Consul token." if settings.fetch("token").match?(/[\s\p{Cntrl}]/)
  end

  def validate_integrations!(supplied, production)
    if production
      raise Error, "Production requires OIDC authentication." unless dig("authentication", "mode") == "oidc"

      required!(supplied.fetch("server", {}), %w[secret_key_base allowed_hosts host], "server")
      raise Error, "Production secret_key_base must contain at least 64 characters." if dig("server", "secret_key_base").size < 64
    end
    if dig("authentication", "mode") == "oidc"
      oidc = dig("authentication", "oidc")
      required!(oidc, %w[issuer client_id client_secret redirect_uri], "authentication.oidc")
      %w[issuer redirect_uri].each { |name| url!(oidc.fetch(name), "OIDC #{name}", https: production) }
    end
    validate_puppetdb! if dig("puppetdb", "enabled")
    required!(dig("integrations", "zabbix"), ["token"], "integrations.zabbix") if dig("integrations", "zabbix", "enabled")
    raise Error, "server.allowed_hosts must not be empty." if dig("server", "allowed_hosts").empty?
  end

  def validate_puppetdb!
    url!(dig("puppetdb", "url"), "PuppetDB URL")
    tls = dig("puppetdb", "tls")
    raise Error, "PuppetDB requires both client certificate and key." if tls["cert_file"].empty? != tls["key_file"].empty?

    tls.each_value { |path| file_path!(path, "PuppetDB TLS") unless path.empty? }
    credentials = !tls["cert_file"].empty? || !dig("puppetdb", "authentication", "token").empty?
    url!(dig("puppetdb", "url"), "PuppetDB URL", https: true) if credentials
    required!(dig("puppetdb", "inventory"), %w[fact_name fingerprint_field], "puppetdb.inventory")
  end

  def validate_reconciliation!
    config = dig("certificates", "reconciliation")
    return if config["missing_after_scans"] >= 2 && config["max_delete_percent"].between?(0, 100)

    raise Error, "Invalid certificates.reconciliation limits."
  end

  def validate_csr!
    config = dig("csr", "defaults")
    sizes = { "RSA" => [2048, 3072, 4096], "EC" => [256, 384, 521] }
    unless sizes.fetch(config["key_algorithm"], []).include?(config["key_size"]) && %w[SHA256 SHA384 SHA512].include?(config["digest"])
      raise Error, "Invalid CSR algorithm, key size or digest."
    end

    country = config.fetch("country")
    raise Error, "Invalid CSR country." unless country.empty? || country.match?(/\A[A-Z]{2}\z/)
  end

  def required!(object, keys, path)
    raise Error, "#{path} is missing a required value." if keys.any? { |key| !object.key?(key) || object[key].to_s.strip.empty? }
  end

  def positive!(*paths)
    paths.each { |path| raise Error, "#{path.join(".")} must be positive." unless dig(*path).positive? }
  end

  def enum!(path, values)
    raise Error, "#{path.join(".")} is unsupported." unless values.include?(dig(*path))
  end

  def url!(value, name, https: false)
    uri = URI(value)
    valid = (https ? ["https"] : %w[http https]).include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
    raise Error, "#{name} must be an HTTP(S) URL without credentials, query or fragment." unless valid
  rescue URI::InvalidURIError
    raise Error, "#{name} is invalid.", cause: nil
  end

  def file_path!(path, name)
    raise Error, "#{name} file must be absolute and readable." unless path.start_with?("/") && File.file?(path) && File.readable?(path)
  end

  def merge(defaults, supplied)
    defaults.merge(supplied) { |_key, base, value| base.is_a?(Hash) && value.is_a?(Hash) ? merge(base, value) : value }
  end

  def freeze_tree(value)
    if value.is_a?(Hash)
      value.each do |key, item|
        key.freeze
        freeze_tree(item)
      end
    end
    value.each { |item| freeze_tree(item) } if value.is_a?(Array)
    value.freeze
  end
end
