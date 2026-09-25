# frozen_string_literal: true

require "logger"
require "json"
require "time"

# Formats framework and application messages as one JSON object per line.
class ContainerLogFormatter < Logger::Formatter
  SUPPRESSED_INFO = [
    /\AStarted (?:GET|POST|PUT|PATCH|DELETE|HEAD) /,
    /\AProcessing by /,
    /\A\s*Parameters: /,
    /\ACompleted \d{3} /,
    /\ARedirected to /,
    /\AFilter chain halted /,
    /\A\s*Rendered /
  ].freeze
  SENSITIVE_KEY = /(?:\A|_)(?:authorization|cookie|password|private_key|secret|token|assertion|code|state|session_state)(?:\z|_)/i

  def call(severity, time, progname, message)
    return "" if suppressed?(severity, message)

    data = structured_message(message, severity)
    payload = {
      timestamp: time.utc.iso8601(6),
      level: severity == "WARN" ? "WARNING" : severity,
      logger: data.delete(:logger) || present(progname) || "cci.framework",
      message: data.delete(:message) || message_text(message)
    }
    payload.merge!(LogContext.current) if defined?(LogContext)
    payload.merge!(data)
    "#{JSON.generate(redact_value(payload))}\n"
  end

  def redact(text)
    result = text.gsub(/-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\z)/m,
      "[FILTERED PRIVATE KEY]")
    secrets.each { |secret| result = result.gsub(secret, "[FILTERED]") }
    result = result.gsub(%r{(https?://)[^\s/@]+:[^\s/@]+@}, '\1[FILTERED]@')
    result = result.gsub(%r{(https?://[^\s?"<>]+)\?[^\s"<>]+}, '\1?[FILTERED]')
    result = result.gsub(
      /((?:authorization|cookie|code|state|session_state|access_token|refresh_token|id_token|client_secret|password)=?)[^\s&"<>]+/i,
      '\1[FILTERED]'
    )
    result.gsub(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, "[FILTERED JWT]")
  end

  private

  def structured_message(message, severity)
    return message.transform_keys(&:to_sym).dup if message.is_a?(Hash)

    if %w[ERROR FATAL].include?(severity)
      match = message.to_s.match(/\A\n?(?<type>[A-Z]\w*(?:::\w+)*) \((?<detail>.*?)\):\n(?<trace>.*)\z/m)
      if match
        return { message: "Unhandled exception", error_type: match[:type],
                 error_message: match[:detail], stacktrace: match[:trace].lines.map(&:strip).reject(&:empty?) }
      end
    end
    if message.is_a?(Exception)
      return { error_type: message.class.name, error_message: message.message,
               stacktrace: Array(message.backtrace) }
    end

    {}
  end

  def message_text(message)
    message.is_a?(Exception) ? message.class.name : message.to_s
  end

  def suppressed?(severity, message)
    return false unless severity == "INFO" && !message.is_a?(Hash)

    SUPPRESSED_INFO.any? { |pattern| pattern.match?(message.to_s) }
  end

  def redact_value(value, key = nil)
    return "[FILTERED]" if key&.match?(SENSITIVE_KEY)

    case value
    when Hash
      value.to_h { |child_key, child_value| [child_key, redact_value(child_value, child_key.to_s)] }
    when Array
      value.map { |entry| redact_value(entry) }
    when String
      redact(value)
    when Symbol
      value.to_s
    when Time
      value.utc.iso8601(6)
    else
      value
    end
  end

  def present(value)
    value unless value.nil? || value.to_s.empty?
  end

  def secrets
    values = ENV.filter_map do |name, value|
      value if name.match?(/(?:TOKEN|SECRET|PASSWORD|_KEY)\z/) && !value.empty?
    end
    values.concat(JSON.parse(ENV.fetch("CCI_AREA_KEYS", "{}")).values) if ENV["CCI_AREA_KEYS"].to_s.start_with?("{")
    values.select { |value| value.is_a?(String) && value.size >= 4 }.sort_by { |value| -value.size }
  rescue JSON::ParserError
    values
  end
end
