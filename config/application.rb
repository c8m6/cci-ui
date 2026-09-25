# frozen_string_literal: true

require_relative "boot"
require "rails"
require_relative "../lib/container_log_formatter"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"
Bundler.require(*Rails.groups)

module Certui
  # Bootstraps the Rails catalogue and the framework-independent certificate utilities.
  class Application < Rails::Application
    config.load_defaults 8.1
    # Always use the application error page, including in development.
    config.consider_all_requests_local = false
    config.action_dispatch.show_exceptions = :all
    config.action_dispatch.log_rescued_responses = true
    config.log_tags = [:request_id]
    stdout_logger = ActiveSupport::Logger.new($stdout)
    stdout_logger.formatter = ContainerLogFormatter.new
    config.logger = ActiveSupport::TaggedLogging.new(stdout_logger)
    config.log_level = :info
    config.action_dispatch.rescue_responses["ConsulConnection::Error"] = :service_unavailable
    %w[ActiveRecord::ConnectionNotEstablished ActiveRecord::ConnectionTimeoutError ActiveRecord::NoDatabaseError].each do |error|
      config.action_dispatch.rescue_responses[error] = :service_unavailable
    end
    config.x.show_error_details = %w[true 1].include?(ENV.fetch("CCI_SHOW_ERROR_DETAILS", "false").downcase)
    config.exceptions_app = lambda do |env|
      # Invalid JSON/query parameters must not fail again in the error renderer.
      clean_env = env.merge("action_dispatch.request.parameters" => {},
        "action_dispatch.request.request_parameters" => {},
        "action_dispatch.request.query_parameters" => {},
        "action_dispatch.request.path_parameters" => {})
      ErrorsController.action(:show).call(clean_env)
    end
    config.time_zone = "Berlin"
    config.i18n.default_locale = :de
    config.i18n.available_locales = Dir[root.join("config/locales/*.yml")].map do |path|
      File.basename(path, ".yml").to_sym
    end
    config.autoload_lib(ignore: %w[assets tasks])
    config.filter_parameters += %i[password private_key key pem content file files token secret authorization
      code state session_state assertion client_assertion revoke_password]
    config.action_dispatch.cookies_same_site_protection = :lax
    config.session_store :cookie_store, key: "_certui", expire_after: 1.hour,
      secure: ENV["RAILS_ENV"] == "production", httponly: true
  end
end
