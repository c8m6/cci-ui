require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"
Bundler.require(*Rails.groups)

module Certui
  class Application < Rails::Application
    config.load_defaults 8.1
    config.time_zone = "Berlin"
    config.i18n.default_locale = :de
    config.i18n.available_locales = Dir[root.join("config/locales/*.yml")].map { |path| File.basename(path, ".yml").to_sym }
    config.autoload_lib(ignore: %w[assets tasks])
    config.filter_parameters += %i[password private_key key pem content file files token secret authorization]
    config.action_dispatch.cookies_same_site_protection = :lax
    config.session_store :cookie_store, key: "_certui", expire_after: 1.hour,
      secure: ENV["RAILS_ENV"] == "production", httponly: true
  end
end
