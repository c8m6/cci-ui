class CertificatesController < ApplicationController
  def index
    visible = Certificate.visible_to(current_identity)
    @stats = { total: visible.where(active: true).count,
      expiring: visible.where(active: true).where("not_after > ? AND not_after < ?", Time.current, 30.days.from_now).count,
      expired: visible.where(active: true).where("not_after <= ?", Time.current).count }
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
    @material = CertificateMaterial.with_chain(@certificate, CertificateMaterial.load(@certificate), current_identity)
    fingerprints = [@material[:certificate], *@material[:chain]].map { |cert| Certificates::Codec.fingerprint(cert) }
    @chain_records = Certificate.visible_to(current_identity).where(area: @certificate.area, fingerprint: fingerprints).order(active: :desc, id: :asc).to_a.group_by(&:fingerprint).transform_values(&:first)
    @hiera = HieraSnippet.for(@certificate, @material[:certificate])
    @versions = @certificate.entry_id ? Certificate.visible_to(current_identity).where(area: @certificate.area, entry_id: @certificate.entry_id).order(not_before: :desc) : []
  end
  def export
    ids = Array(params[:ids]).map(&:to_s).uniq
    raise Certificates::Error, "Bitte zwischen 1 und 100 Zertifikate auswählen." unless (1..100).cover?(ids.size)
    records = Certificate.visible_to(current_identity).where(id: ids).to_a
    return head :not_found unless records.size == ids.size
    content, filename, type = CertificateExport.call(records, identity: current_identity,
      format: params[:format_name], include_key: params[:include_key] == "1", include_chain: params[:include_chain] == "1",
      password: params[:password].to_s, source_password: params[:source_password].to_s)
    send_data content, filename: filename, type: type, disposition: "attachment"
  end
  def update
    record = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(record.area)
    raise Certificates::Error, "Der Dateibestand ist nur lesbar." unless record.source == "consul"
    ConsulStore.activate(record.area, record.source_id, actor: current_identity.name)
    CatalogIndexer.refresh_consul
    redirect_to certificate_path(record), notice: "Version für Puppet aktiviert.", status: :see_other
  end
  def destroy
    record = Certificate.visible_to(current_identity).find(params[:id])
    require_writer!(record.area)
    raise Certificates::Error, "Der Dateibestand ist nur lesbar." unless record.source == "consul"
    ConsulStore.delete(record.area, record.source_id, actor: current_identity.name)
    record.destroy!
    redirect_to root_path, notice: "Inaktive Version gelöscht.", status: :see_other
  end
end
