# frozen_string_literal: true

mode = ENV.fetch("AUTH_MODE", "oidc")
raise "AUTH_MODE must be oidc or local" unless %w[oidc local].include?(mode)
raise "Local sign-in is prohibited in production" if Rails.env.production? && mode == "local"

if mode == "oidc"
  require Rails.root.join("lib/keycloak_logging")
  require Rails.root.join("lib/keycloak_http_logging")
  OmniAuth::Strategies::OpenIDConnect.prepend(KeycloakLogging)
  # Keep provider exceptions out of Rails request dumps in every environment.
  OmniAuth.config.failure_raise_out_environments = []
  OpenIDConnect.http_config do |http|
    http.options.open_timeout = 5
    http.options.timeout = 15
    # Wrap the JSON response parser so malformed provider responses can be
    # attributed to the concrete endpoint without logging their bodies.
    http.builder.insert_before(Faraday::Response::Json, KeycloakHttpLogging)
  end
  issuer = ENV.fetch("OIDC_ISSUER")
  raise "OIDC_ISSUER requires HTTPS" if Rails.env.production? && !issuer.start_with?("https://")

  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, name: :keycloak, scope: %i[openid profile email],
      response_type: :code, issuer: issuer, discovery: true, pkce: true,
      uid_field: "sub", client_options: {
        identifier: ENV.fetch("OIDC_CLIENT_ID"), secret: ENV.fetch("OIDC_CLIENT_SECRET"),
        redirect_uri: ENV.fetch("OIDC_REDIRECT_URI")
      }
  end
end
