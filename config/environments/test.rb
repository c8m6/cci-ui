Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.secret_key_base = "test-only-" * 16
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
end
