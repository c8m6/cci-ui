# frozen_string_literal: true

# Carries request and batch correlation metadata through synchronous work.
module LogContext
  THREAD_KEY = :cci_ui_log_context

  def self.current
    Thread.current[THREAD_KEY] || {}
  end

  def self.with(**fields)
    previous = Thread.current[THREAD_KEY]
    Thread.current[THREAD_KEY] = current.merge(fields.compact)
    yield
  ensure
    Thread.current[THREAD_KEY] = previous
  end

  def self.correlation_id
    current[:request_id] || current[:correlation_id]
  end
end
