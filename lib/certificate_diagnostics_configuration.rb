# frozen_string_literal: true

require "ipaddr"
require "uri"
require_relative "trust_profile_configuration"

# One validated contract shared by the web presentation and the indexer.
class CertificateDiagnosticsConfiguration
  CHECKS = { "ocsp" => 21_600, "crl" => 21_600 }.merge(TrustProfileConfiguration::DEFAULTS.transform_values { 86_400 }).freeze
  LIMITS = { "batch_size" => 20, "pass_budget" => 15, "request_timeout" => 5,
             "connect_timeout" => 3, "max_bytes" => 5_242_880, "redirects" => 3,
             "evidence_max_age" => 21_600, "clock_skew" => 300 }.freeze

  attr_reader :checks, :limits, :allowed_networks, :trust, :http_proxy

  def initialize(environment = ENV)
    @trust = TrustProfileConfiguration.new(environment)
    @http_proxy = proxy(environment["CCI_DIAGNOSTICS_HTTP_PROXY"])
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

  def groups
    { "revocation" => %w[ocsp crl], "browsers" => %w[trust_chrome trust_firefox trust_edge trust_apple],
      "system" => %w[trust_ubuntu] }.transform_values { |checks| checks & enabled }.reject { |_, checks| checks.empty? }
  end

  def version(check)
    profile = trust.profiles[check]
    Digest::SHA256.hexdigest([check, checks.fetch(check), limits, allowed_networks.map(&:to_s), http_proxy&.to_s, profile].to_json)
  end

  private

  def proxy(value)
    return if value.to_s.strip.empty?

    uri = URI.parse(value.strip)
    valid = uri.is_a?(URI::HTTP) && uri.scheme == "http" && uri.hostname && !uri.hostname.empty? &&
            uri.port.between?(1, 65_535) && ["", "/"].include?(uri.path) && !uri.query && !uri.fragment
    raise URI::InvalidURIError unless valid

    uri
  rescue URI::InvalidURIError, URI::InvalidComponentError
    raise ArgumentError, "CCI_DIAGNOSTICS_HTTP_PROXY must be an HTTP proxy URL with an optional port and credentials.", cause: nil
  end

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
