class AuditEventsController < ApplicationController
  def index
    return head :forbidden unless current_identity.auditor?
    events = AuditEvent.visible_to(current_identity)
    events = events.where(area: params[:area]) if params[:area].present?
    events = events.where(action: params[:event_action]) if params[:event_action].present?
    if params[:q].present?
      query = "%#{AuditEvent.sanitize_sql_like(params[:q].to_s.strip)}%"
      events = events.where("actor ILIKE :q OR details::text ILIKE :q OR \"references\"::text ILIKE :q", q: query)
    end
    events = events.where("occurred_at >= ?", audit_date(:from).beginning_of_day) if params[:from].present?
    events = events.where("occurred_at < ?", audit_date(:to).next_day.beginning_of_day) if params[:to].present?
    @total = events.count
    @pages = [(@total / 30.0).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @pages)
    @events = events.order(occurred_at: :desc, id: :desc).limit(30).offset((@page - 1) * 30)
  rescue ArgumentError, Date::Error
    render plain: I18n.t("errors.app.invalid_dates"), status: :unprocessable_entity
  end

  private

  def audit_date(key)
    Date.iso8601(params[key].to_s).in_time_zone
  end
end
