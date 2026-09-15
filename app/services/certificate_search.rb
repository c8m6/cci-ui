class CertificateSearch
  SORTS = { "ablauf" => { not_after: :asc }, "name" => { common_name: :asc }, "neueste" => { not_before: :desc } }.freeze
  def self.call(scope, params)
    scope = scope.where(active: true) unless params[:history] == "1"
    scope = scope.where(area: params[:area]) if AreaConfiguration.ids.include?(params[:area])
    scope = scope.where(source: params[:source]) if %w[filesystem consul].include?(params[:source])
    scope = scope.where(has_key: params[:key] == "1") if %w[0 1].include?(params[:key])
    scope = scope.where(rollout_status: params[:rollout_status]) if ConsulStore::ROLLOUT_STATUSES.include?(params[:rollout_status])
    now = Time.current
    scope = case params[:status]
    when "expired" then scope.where("not_after <= ?", now)
    when "soon" then scope.where("not_before <= ? AND not_after > ? AND not_after <= ?", now, now, now + 30.days)
    when "valid" then scope.where("not_before <= ? AND not_after > ?", now, now)
    when "future" then scope.where("not_before > ?", now)
    else scope
    end
    params[:q].to_s.first(500).split(/\s+/).first(20).each do |term|
      normalized = term.delete(":").downcase
      scope = scope.where("search_text ILIKE :term OR fingerprint = :exact OR serial = :exact",
        term: "%#{ActiveRecord::Base.sanitize_sql_like(term)}%", exact: normalized)
    end
    scope.order(SORTS.fetch(params[:sort], SORTS["ablauf"])).order(:id)
  end
end
