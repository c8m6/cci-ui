# frozen_string_literal: true

# New operations select exactly one area; historical assignments remain intact.
module CertificateAreaConfiguration
  def self.validate_selection!(areas)
    normalized = Array(areas).filter_map { |area| area.to_s.presence }.uniq
    raise Certificates::Error, I18n.t("errors.app.choose_area") unless normalized.one? && AreaConfiguration.ids.include?(normalized.first)

    normalized
  end
end
