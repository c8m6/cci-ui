Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "local-development-only-" * 8)
  config.hosts += ENV.fetch("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
end
