mode = ENV.fetch("AUTH_MODE", "oidc")
raise "AUTH_MODE muss oidc oder local sein" unless %w[oidc local].include?(mode)
raise "Lokale Anmeldung ist in Produktion verboten" if Rails.env.production? && mode == "local"
if mode == "oidc"
  issuer = ENV.fetch("OIDC_ISSUER")
  raise "OIDC_ISSUER benötigt HTTPS" if Rails.env.production? && !issuer.start_with?("https://")
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, name: :keycloak, scope: %i[openid profile email],
      response_type: :code, issuer: issuer, discovery: true, pkce: true,
      uid_field: "sub", client_options: {
        identifier: ENV.fetch("OIDC_CLIENT_ID"), secret: ENV.fetch("OIDC_CLIENT_SECRET"),
        redirect_uri: ENV.fetch("OIDC_REDIRECT_URI")
      }
  end
end
