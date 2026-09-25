# frozen_string_literal: true

require "json"
require "time"
require "socket"
require "timeout"
require "uri"
require "logger"
require_relative "log_context"
require_relative "container_log_formatter"

# Routes application events through the same structured logger as Rails.
module OperationalLog
  LEVELS = { "DEBUG" => Logger::DEBUG, "INFO" => Logger::INFO, "WARN" => Logger::WARN,
             "WARNING" => Logger::WARN, "ERROR" => Logger::ERROR, "FATAL" => Logger::FATAL }.freeze
  REASONS = {
    /certificate verify failed/ => "certificate verification failed: check CA trust and certificate chain",
    /hostname mismatch/ => "TLS hostname does not match the certificate",
    /certificate has expired/ => "TLS certificate has expired",
    /unable to get local issuer/ => "TLS issuer CA is missing",
    /certificate required/ => "server requires a client certificate",
    /read.only/i => "database is read-only",
    /migrations are pending/ => "database migrations are pending",
    /incomplete result/ => "response count differs from X-Records",
    /filtered by ACLs/ => "Consul results are filtered by ACLs",
    /issuer mismatch/ => "OIDC discovery issuer mismatch",
    /directory is not readable/ => "inventory directory missing or unreadable: check mounts and permissions"
  }.freeze

  # Resolves stdout at write time so boot failures and tests use the active stream.
  class DynamicOutput
    def write(value) = $stdout.write(value)
    def close; end
  end

  def self.resolve_level(value = ENV.fetch("LOG_LEVEL", "INFO"))
    normalized = value.to_s.upcase
    return [normalized == "WARNING" ? :warn : normalized.downcase.to_sym, nil] if LEVELS.key?(normalized)

    [:info, value]
  end

  def self.configure(logger)
    @target = logger
  end

  def self.log(level, logger:, message:, **fields)
    target.public_send(level, { logger: logger, message: message,
                                process: ENV.fetch("CCI_PROCESS", "rails"), **fields }.compact)
  end

  %i[debug info warn error fatal].each do |level|
    define_singleton_method(level) do |logger:, message:, **fields|
      log(level, logger: logger, message: message, **fields)
    end
  end

  def self.failure(logger:, message:, error:, level: :error, **fields)
    causes = []
    seen = []
    current = error
    while current && !seen.include?(current.object_id)
      seen << current.object_id
      causes << { error_type: current.class.name, error_message: current.message, reasons: reasons(current) }
      current = current.cause
    end
    stacktrace = Array(error.backtrace) if %i[debug error fatal].include?(level)
    log(level, logger: logger, message: message, **fields,
      error_type: error.class.name, error_message: error.message, causes: causes,
      stacktrace: stacktrace)
  end

  def self.reasons(error)
    message = error.message
    reasons = REASONS.filter_map { |pattern, explanation| explanation if pattern.match?(message) }
    status = message[/\bHTTP ([1-5][0-9]{2})\b/, 1]
    reasons << "HTTP #{status}" if status
    reasons << "invalid JSON response (body omitted)" if error.is_a?(JSON::ParserError)
    reasons << "check required environment configuration" if error.is_a?(KeyError)
    reasons << "check DNS resolution" if error.is_a?(SocketError)
    reasons << "file or directory missing: check container mounts" if error.is_a?(Errno::ENOENT)
    reasons << "permission denied: check container UID and file permissions" if error.is_a?(Errno::EACCES)
    reasons << "connection refused: check host, port and listener" if error.is_a?(Errno::ECONNREFUSED)
    reasons << "network timeout: check routing, firewall and service response time" if error.is_a?(Timeout::Error)
    reasons
  end

  def self.configuration(service)
    prefix = { "consul" => "CONSUL", "puppetdb" => "PUPPETDB", "oidc" => "OIDC" }[service]
    return {} unless prefix

    url = ENV.fetch(prefix == "OIDC" ? "OIDC_ISSUER" : "#{prefix}_URL", "")
    uri = URI.parse(url)
    files = %W[#{prefix}_CA_FILE #{prefix}_CLIENT_CERT_FILE #{prefix}_CLIENT_KEY_FILE SSL_CERT_FILE]
    { endpoint: { scheme: uri.scheme, host: uri.host, port: uri.port },
      files: files.filter_map do |name|
        path = ENV[name].to_s
        next if path.empty?

        { setting: name, exists: File.file?(path), readable: File.readable?(path) }
      end }
  rescue URI::InvalidURIError
    { endpoint: "invalid URL" }
  end

  def self.startup
    info(logger: "cci.startup", message: "Startup health checks started", operation: "startup_health")
    failures = ApplicationHealth.check.merge(ApplicationReadiness.check)
    failures.each do |service, error|
      failure(logger: "cci.startup", message: "Startup health check failed", error: error,
        service: service, operation: "startup_health", configuration: configuration(service))
    end
    info(logger: "cci.startup", message: "Startup health checks completed", operation: "startup_health",
      result: failures.empty? ? "healthy" : "unhealthy")
  rescue StandardError => e
    failure(logger: "cci.startup", message: "Startup health checks failed", error: e,
      service: "application", operation: "startup_health")
  end

  def self.target
    @target ||= Logger.new(DynamicOutput.new).tap do |logger|
      level, = resolve_level
      logger.level = level
      logger.formatter = ContainerLogFormatter.new
    end
  end
end
