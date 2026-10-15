# frozen_string_literal: true

# Reads permission-scoped local projections without probing external services.
class DashboardController < ApplicationController
  def index
    records = Certificate.visible_to(current_identity)
    @stats = statistics(records)
    @open_csrs = CertificateRequest.visible_to(current_identity).where.missing(:csr_certificates).count
    @areas = current_identity.areas.sort_by { |area| [AreaConfiguration.label(area).downcase, area] }
    @area_stats = @areas.to_h { |area| [area, statistics(records.where(area: area))] }
    @attention = records.order(:not_after, :id).limit(5)
    @freshness = CaInventory.where(area: current_identity.areas).index_by(&:area)
    @puppetdb_failures = records.where.not(puppetdb_error_at: nil).distinct.count(:area) if PuppetdbConfiguration.enabled?
  end

  private

  def statistics(records)
    result = { total: records.count }
    { valid: "valid", expiring: "soon", expired: "expired" }.each do |key, status|
      result[key] = CertificateSearch.filter_validity(records, status).count
    end
    if PuppetdbConfiguration.enabled?
      result[:hosts] = records.joins("CROSS JOIN LATERAL jsonb_array_elements_text(puppetdb_hosts) AS host(name)")
                              .distinct.count("host.name")
    end
    result
  end
end
