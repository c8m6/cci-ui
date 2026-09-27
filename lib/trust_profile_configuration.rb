# frozen_string_literal: true

# Public source targets are independent of transport CAs and local inventory.
class TrustProfileConfiguration
  DEFAULTS = { "trust_chrome" => "154.0.8037.57", "trust_firefox" => "156.0.1",
               "trust_edge" => "windows-macos", "trust_apple" => "macos-15-2024051500",
               "trust_ubuntu" => "noble-updates" }.freeze
  LIMITS = { "request_timeout" => 10, "max_bytes" => 20_971_520, "expanded_max_bytes" => 67_108_864 }.freeze

  attr_reader :profiles, :limits

  def initialize(environment = ENV)
    @profiles = DEFAULTS.to_h do |check, target|
      stem = "CCI_#{check.upcase}"
      selected = environment.fetch("#{stem}_TARGET", target)
      valid = %w[trust_chrome trust_firefox].include?(check) ? selected.match?(/\A\d+\.\d+\.\d+(?:\.\d+)?\z/) : selected == target
      raise ArgumentError, "#{stem}_TARGET is unsupported (default: #{target})." unless valid

      [check, { "target" => selected, "update_interval" => positive(environment, "#{stem}_UPDATE_INTERVAL", 86_400),
                "max_age" => positive(environment, "#{stem}_MAX_AGE", 604_800) }]
    end
    @limits = LIMITS.to_h { |key, default| [key, positive(environment, "CCI_TRUST_#{key.upcase}", default)] }
  end

  def [](check) = profiles.fetch(check)

  private

  def positive(environment, name, default)
    value = Integer(environment.fetch(name, default.to_s), 10)
    raise ArgumentError unless value.positive?

    value
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a positive integer."
  end
end
