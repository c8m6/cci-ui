# frozen_string_literal: true

require "faraday"

# Observes OIDC HTTP exchanges without logging headers, bodies, redirects or tokens.
class KeycloakHttpLogging < Faraday::Middleware
  def call(env)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    correlation_id = LogContext.correlation_id
    env.request_headers["X-Request-ID"] = correlation_id if correlation_id
    fields = {
      system: "keycloak",
      operation: operation(env.url.path),
      http_method: env.method.to_s.upcase,
      endpoint: endpoint(env.url)
    }
    OperationalLog.debug(logger: "cci.keycloak", message: "Keycloak request started", **fields)
    @app.call(env).on_complete do |response|
      status = response.status.to_i
      message = [401, 403].include?(status) ? "Authentication rejected by Keycloak" : "Keycloak request completed"
      OperationalLog.debug(logger: "cci.keycloak", message: message, **fields, http_status: status,
        duration_ms: elapsed_ms(started),
        result: [401, 403].include?(status) ? "upstream_authentication_rejected" : "success")
    end
  rescue Faraday::Error => e
    safe_error = StandardError.new("Keycloak HTTP request failed")
    safe_error.set_backtrace(e.backtrace)
    OperationalLog.failure(logger: "cci.keycloak", message: "Keycloak request failed", error: safe_error,
      level: :warn, **fields, http_status: response_status(e), duration_ms: elapsed_ms(started),
      upstream_error_type: e.class.name, reason: "connection_or_http_error")
    raise
  end

  private

  def operation(path)
    return "oidc_discovery" if path.include?(".well-known")
    return "token_exchange" if path.end_with?("/token")
    return "userinfo" if path.end_with?("/userinfo")
    return "signing_keys" if path.end_with?("/certs")

    "oidc_http_request"
  end

  def endpoint(uri)
    URI::Generic.build(scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path).to_s
  end

  def response_status(error)
    error.response_status if error.respond_to?(:response_status)
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
end
