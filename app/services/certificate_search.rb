# frozen_string_literal: true

# Applies catalogue filters to an already authorised relation with allowlisted sorting.
class CertificateSearch
  SORTS = { "expiry" => { not_after: :asc }, "name" => { common_name: :asc },
            "newest" => { not_before: :desc } }.freeze
  def self.call(scope, params)
    include_archived = params[:q].to_s.strip.present? || params[:archived] == "1"
    scope = scope.where(archived: false) unless include_archived
    unless params[:history] == "1"
      scope = include_archived ? scope.where("active = TRUE OR archived = TRUE") : scope.where(active: true)
    end
    scope = scope.where(area: params[:area]) if AreaConfiguration.ids.include?(params[:area])
    scope = scope.where(source: params[:source]) if %w[filesystem consul].include?(params[:source])
    scope = scope.where(has_key: params[:key] == "1") if %w[0 1].include?(params[:key])
    if ConsulStore::ROLLOUT_STATUSES.include?(params[:rollout_status])
      scope = scope.where(source: "consul", rollout_status: params[:rollout_status])
    end
    scope = filter_validity(scope, params[:status])
    params[:q].to_s.first(500).split(/\s+/).first(20).each do |term|
      normalized = term.delete(":").downcase
      scope = scope.where("search_text ILIKE :term OR fingerprint = :exact OR serial = :exact",
        term: "%#{ActiveRecord::Base.sanitize_sql_like(term)}%", exact: normalized)
    end
    scope.order(SORTS.fetch(params[:sort], SORTS["expiry"])).order(:id)
  end

  def self.filter_validity(scope, status)
    now = Time.current
    case status
    when "expired" then scope.where("not_after <= ?", now)
    when "soon" then scope.where("not_before <= ? AND not_after > ? AND not_after <= ?", now, now,
      now + 30.days)
    when "valid" then scope.where("not_before <= ? AND not_after > ?", now, now)
    when "future" then scope.where("not_before > ?", now)
    else scope
    end
  end
end
