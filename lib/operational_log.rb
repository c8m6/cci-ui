# frozen_string_literal: true

require "json"
require "time"
require "socket"
require "timeout"
require "uri"

# Emits metadata only, excluding exception messages, SQL values and response bodies.
module OperationalLog
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

  def self.emit(event, **fields)
    $stdout.puts(JSON.generate(time: Time.now.utc.iso8601(6), event: event,
      process: ENV.fetch("CCI_PROCESS", "rails"), pid: Process.pid, **fields))
    $stdout.flush
  end

  def self.failure(event, error, **fields)
    causes = []
    seen = []
    while error && !seen.include?(error.object_id)
      seen << error.object_id
      causes << { type: error.class.name, reasons: reasons(error) }
      error = error.cause
    end
    emit(event, **fields, causes: causes)
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

  def self.database_write(payload)
    sql = payload[:sql].to_s
    match = sql.match(/\A\s*(INSERT INTO|UPDATE|DELETE FROM)\s+"?([a-zA-Z_][a-zA-Z_0-9]*)"?/i)
    transaction = sql.strip.upcase
    return unless match || %w[BEGIN COMMIT ROLLBACK].include?(transaction)

    emit("database.write", operation: match ? match[1].upcase : transaction,
      table: match && match[2], outcome: payload[:exception] ? "failed" : "executed",
      affected_rows: payload[:affected_rows], connection: payload[:connection]&.object_id)
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
    emit("startup.health.started")
    failures = ApplicationHealth.check.merge(ApplicationReadiness.check)
    failures.each { |service, error| failure("startup.health.failed", error, service: service, configuration: configuration(service)) }
    emit("startup.health.completed", outcome: failures.empty? ? "healthy" : "unhealthy")
  rescue StandardError => e
    failure("startup.health.failed", e, service: "application")
  end
end
