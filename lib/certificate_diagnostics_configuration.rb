# frozen_string_literal: true

require "ipaddr"

# One validated contract shared by the web presentation and the indexer.
class CertificateDiagnosticsConfiguration
  CHECKS = { "ocsp" => 21_600, "crl" => 21_600 }.freeze
  LIMITS = { "batch_size" => 20, "pass_budget" => 15, "request_timeout" => 5,
             "connect_timeout" => 3, "max_bytes" => 5_242_880, "redirects" => 3,
             "evidence_max_age" => 21_600, "clock_skew" => 300 }.freeze

  attr_reader :checks, :limits, :allowed_networks

  def initialize(environment = ENV)
    @checks = CHECKS.to_h do |check, interval|
      stem = "CCI_#{check.upcase}"
      [check, { enabled: boolean(environment, "#{stem}_ENABLED"), interval: positive(environment, "#{stem}_INTERVAL", interval) }]
    end
    @limits = LIMITS.to_h { |key, default| [key, positive(environment, "CCI_DIAGNOSTICS_#{key.upcase}", default)] }
    @allowed_networks = environment.fetch("CCI_DIAGNOSTICS_ALLOWED_NETWORKS", "").split(",").map do |value|
      IPAddr.new(value.strip)
    rescue IPAddr::InvalidAddressError
      raise ArgumentError, "CCI_DIAGNOSTICS_ALLOWED_NETWORKS must contain comma-separated IP addresses or CIDRs."
    end
  end

  def enabled?(check) = checks.fetch(check).fetch(:enabled)
  def interval(check) = checks.fetch(check).fetch(:interval)
  def enabled = checks.keys.select { |check| enabled?(check) }
  def [](key) = limits.fetch(key.to_s)
  def version(check) = Digest::SHA256.hexdigest([check, checks.fetch(check), limits, allowed_networks.map(&:to_s)].to_json)

  private

  def boolean(environment, name)
    case environment.fetch(name, "false").strip.downcase
    when "true", "1" then true
    when "false", "0" then false
    else raise ArgumentError, "#{name} must be true or false."
    end
  end

  def positive(environment, name, default)
    value = Integer(environment.fetch(name, default.to_s), 10)
    raise ArgumentError unless value.positive?

    value
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a positive integer."
  end
end
