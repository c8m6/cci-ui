# frozen_string_literal: true

# Controls whether one certificate may be assigned to one or several areas.
module CertificateAreaConfiguration
  MODES = %w[single multiple].freeze
  DEFAULT_MODE = "multiple"

  def self.mode(environment = ENV)
    value = environment.fetch("CCI_CERTIFICATE_AREA_MODE", DEFAULT_MODE).to_s.strip
    value = DEFAULT_MODE if value.empty?
    return value if MODES.include?(value)

    raise ArgumentError, "CCI_CERTIFICATE_AREA_MODE must be single or multiple."
  end

  def self.multiple?(environment = ENV) = mode(environment) == "multiple"

  def self.validate_selection!(areas, environment = ENV)
    normalized = Array(areas).filter_map { |area| area.to_s.presence }.uniq
    valid = normalized.any? && (normalized - AreaConfiguration.ids).empty?
    valid &&= normalized.one? unless multiple?(environment)
    raise Certificates::Error, I18n.t("errors.app.choose_area") unless valid

    normalized
  end

  def self.validate_fingerprint!(fingerprint, areas:, environment: ENV)
    return if multiple?(environment)

    other_area = Certificate.retained.where(fingerprint: fingerprint).where.not(area: areas).exists?
    raise Certificates::Error, I18n.t("errors.app.certificate_other_area") if other_area
  end
end
