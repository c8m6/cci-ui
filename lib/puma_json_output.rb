# frozen_string_literal: true

require_relative "container_log_formatter"

# Adapts Puma's stdout and stderr streams to the application JSON schema.
class PumaJsonOutput
  LEVELS = { "DEBUG" => Logger::DEBUG, "INFO" => Logger::INFO, "WARN" => Logger::WARN,
             "WARNING" => Logger::WARN, "ERROR" => Logger::ERROR, "FATAL" => Logger::FATAL }.freeze

  def initialize(io, level:)
    @io = io
    @level = level
    @severity = LEVELS.fetch(level)
    @threshold = LEVELS.fetch(ENV.fetch("LOG_LEVEL", "INFO").upcase, Logger::INFO)
    @formatter = ContainerLogFormatter.new
  end

  def write(value)
    message = value.to_s.sub(/\n\z/, "")
    return 0 if message.empty? || @severity < @threshold

    data = { logger: "puma", message: message }
    if %w[ERROR FATAL].include?(@level)
      data[:error_type] = "PumaError"
      data[:error_message] = message
    end
    @io.write(@formatter.call(@level, Time.now, "puma", data))
  end

  def flush
    @io.flush
  end

  def sync
    @io.sync
  end
end
