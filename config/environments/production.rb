# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.force_ssl = true
  config.assume_ssl = true
  config.secret_key_base = CciConfiguration.current.dig("server", "secret_key_base")
  config.hosts = CciConfiguration.current.dig("server", "allowed_hosts")
end
