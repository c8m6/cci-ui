Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true
  config.assume_ssl = true
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
  config.hosts = ENV.fetch("ALLOWED_HOSTS").split(",")
  config.log_level = :info
end
