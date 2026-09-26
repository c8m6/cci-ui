# frozen_string_literal: true

# Provides build information injected by the container build without requiring Git at runtime.
module ApplicationBuild
  DEFAULTS = { version: "development", revision: "unknown", build_time: "unknown" }.freeze

  def self.version = value("APP_VERSION", DEFAULTS.fetch(:version))
  def self.revision = value("APP_REVISION", DEFAULTS.fetch(:revision))
  def self.build_time = value("APP_BUILD_TIME", DEFAULTS.fetch(:build_time))

  def self.to_h
    { version: version, revision: revision, build_time: build_time }
  end

  def self.value(name, fallback)
    configured = ENV[name].to_s.strip
    configured.empty? ? fallback : configured
  end
  private_class_method :value
end
