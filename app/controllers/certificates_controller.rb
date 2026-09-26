# frozen_string_literal: true

# Presents the catalogue and authorises exports, version changes and archiving.
class CertificatesController < ApplicationController
  def index
    visible = Certificate.visible_to(current_identity)
    @stats = { total: visible.where(active: true, archived: false).count,
               expiring: visible.where(active: true, archived: false).where("not_after > ? AND not_after < ?", Time.current,
                 30.days.from_now).count,
               expired: visible.where(active: true, archived: false).where("not_after <= ?", Time.current).count }
    results = CertificateSearch.call(visible, params)
    @total = results.count
    @page = [params[:page].to_i, 1].max
    @pages = [(@total / 30.0).ceil, 1].max
    @page = [@page, @pages].min
    @certificates = results.limit(30).offset((@page - 1) * 30)
    @indexed_at = visible.maximum(:indexed_at)
  end

  def show
    @certificate = Certificate.visible_to(current_identity).find(params[:id])
    @certid_snapshot = ConsulStore.status_snapshot(@certificate)
    status_entry = @certid_snapshot && JSON.parse(@certid_snapshot.fetch(:value))
    @rollout_status = status_entry ? ConsulStore.rollout_status(status_entry) : @certificate.rollout_status
    @archived = @certificate.archived || (status_entry && ConsulStore.catalog_status(status_entry).fetch(:archived))
    @versions = if @certificate.certid
                  Certificate.visible_to(current_identity).where(area: @certificate.area,
                    source: "consul", certid: @certificate.certid).order(certificate_version: :desc)
                else
                  []
                end
    begin
      @material = CertificateMaterial.with_chain(@certificate, CertificateMaterial.load(@certificate), current_identity)
      fingerprints = [@material[:certificate], *@material[:chain]].map { |cert| Certificates::Codec.fingerprint(cert) }
      @chain_records = Certificate.visible_to(current_identity).where(area: @certificate.area, fingerprint: fingerprints).order(
        active: :desc, id: :asc
      ).to_a.group_by(&:fingerprint).transform_values(&:first)
      @hiera = HieraSnippet.for(@certificate, @material[:certificate])
    rescue Certificates::Error, ConsulConnection::Error => e
      OperationalLog.failure(logger: "cci.certificates", message: "Certificate material loading failed", error: e,
        certificate_id: @certificate.id)
      @material = nil
      @material_error = e.is_a?(ConsulConnection::Error) ? I18n.t("errors.app.store_unavailable") : e.message
    end
  end

  def archive
    @certificate = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(@certificate.area)
    require_consul!(@certificate)
    @certid_snapshot = ConsulStore.status_snapshot(@certificate)
  end

  def delete_legacy
    @certificate = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(@certificate.area)
    @deletion = LegacyDeletion.new(@certificate).preview
  end

  def destroy_legacy
    @certificate = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(@certificate.area)
    unless params[:confirm_delete] == "1"
      @deletion = LegacyDeletion.new(@certificate).preview
      flash.now[:alert] = I18n.t("errors.app.deletion_confirmation")
      return render :delete_legacy, status: :unprocessable_content
    end

    LegacyDeletion.new(@certificate).call(token: params[:deletion_token], actor: current_identity.uid,
      actor_display_name: current_identity.display_name)
    redirect_to root_path, notice: I18n.t("notices.legacy_deleted"), status: :see_other
  end

  def export
    ids = Array(params[:ids]).map(&:to_s).uniq
    raise Certificates::Error, I18n.t("errors.app.export_count") unless (1..100).cover?(ids.size)

    records = Certificate.visible_to(current_identity).where(id: ids).to_a
    return render_error(:not_found) unless records.size == ids.size

    content, filename, type = CertificateExport.call(records, identity: current_identity,
      format: params[:format_name], include_key: params[:include_key] == "1", include_chain: params[:include_chain] == "1",
      password: params[:password].to_s, source_password: params[:source_password].to_s)
    send_data content, filename: filename, type: type, disposition: "attachment"
  end

  def update
    record = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(record.area)
    require_consul!(record)
    raise Certificates::Error, I18n.t("errors.app.archived_reactivation") if record.archived && params[:archive] != "1"

    if params[:archive] == "1"
      unless params[:confirm_archive] == "1"
        @certificate = record
        @certid_snapshot = ConsulStore.status_snapshot(record)
        flash.now[:alert] = I18n.t("errors.app.archive_confirmation")
        return render :archive, status: :unprocessable_content
      end
      ConsulStore.archive(record, actor: current_identity.uid, actor_display_name: current_identity.display_name,
        expected_certid_index: params[:certid_index])
      notice = I18n.t("notices.archived")
    elsif params.key?(:rollout_status)
      change_rollout_status(record)
      notice = I18n.t("notices.status_saved")
    else
      ConsulStore.activate(record.area, record.source_id, actor: current_identity.uid,
        actor_display_name: current_identity.display_name)
      notice = I18n.t("notices.version_activated")
    end
    CatalogIndexer.refresh_consul
    redirect_to certificate_path(record), notice: notice, status: :see_other
  end

  private

  def require_consul!(record)
    raise Certificates::Error, I18n.t("errors.app.consul_only") unless record.source == "consul"
  end

  def change_rollout_status(record)
    options = { status: params[:rollout_status], actor: current_identity.uid,
                actor_display_name: current_identity.display_name, expected_certid_index: params[:certid_index] }
    ConsulStore.set_status(record.area, record.source_id, **options)
  end
end
