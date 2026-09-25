# frozen_string_literal: true

require "logger"
require "json"

# Redacts framework log messages in addition to Rails parameter filtering.
class ContainerLogFormatter < Logger::Formatter
  def call(severity, time, progname, message)
    super(severity, time, progname, redact(message.to_s))
  end

  def redact(text)
    result = text.gsub(/-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\z)/m, "[FILTERED PRIVATE KEY]")
    secrets.each { |secret| result = result.gsub(secret, "[FILTERED]") }
    result = result.gsub(%r{(https?://)[^\s/@]+:[^\s/@]+@}, '\1[FILTERED]@')
    result = result.gsub(%r{(https?://[^\s?"<>]+)\?[^\s"<>]+}, '\1?[FILTERED]')
    result.gsub(/((?:code|state|session_state|access_token|refresh_token|id_token|client_secret|password)=)[^\s&"<>]+/i,
      '\1[FILTERED]')
  end

  private

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
