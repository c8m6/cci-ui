# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.secret_key_base = CciConfiguration.current.dig("server", "secret_key_base").presence || ("local-development-only-" * 8)
  config.hosts += CciConfiguration.current.dig("server", "allowed_hosts")
end
