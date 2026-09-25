# frozen_string_literal: true

require "securerandom"

# Validates request IDs and adds one structured completion event per request.
class RequestLogContext
  SAFE_ID = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/

  def initialize(app)
    @app = app
  end

  def call(env)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    incoming = env["HTTP_X_REQUEST_ID"].to_s
    request_id = SAFE_ID.match?(incoming) ? incoming : SecureRandom.uuid
    env["action_dispatch.request_id"] = request_id
    LogContext.with(request_id: request_id) do
      status, headers, body = @app.call(env)
      headers["X-Request-Id"] = request_id
      OperationalLog.info(logger: "cci.http", message: "HTTP request completed",
        http_method: env.fetch("REQUEST_METHOD"), endpoint: env.fetch("PATH_INFO"), http_status: status,
        duration_ms: elapsed_ms(started))
      [status, headers, body]
    end
  end

  private

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
end
