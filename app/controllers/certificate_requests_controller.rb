# frozen_string_literal: true

# CSR-only endpoints remain available to existing sessions during Consul outages.
class CertificateRequestsController < ApplicationController
  skip_before_action :require_dependencies
  before_action :require_csr
  before_action :load_request, except: %i[index new create]

  rescue_from Certificates::Error do |error|
    # Services only expose fixed, localized validation messages.
    if request.format.json?
      render json: { error: error.message }, status: :unprocessable_content
    else
      redirect_to(@csr ? certificate_request_path(@csr) : new_certificate_request_path,
        alert: error.message, status: :see_other)
    end
  end

  def index
    scope = CertificateRequest.visible_to(current_identity)
    @open_requests = scope.where.missing(:csr_certificates).order(created_at: :desc)
    @issued = CsrCertificate.joins(:certificate_request).where(certificate_requests: { area: current_identity.csr_areas })
                            .includes(:certificate_request).order(created_at: :desc)
    respond_to do |format|
      format.html
      format.json do
        render json: { open: @open_requests.map { |csr| public_request(csr) }, issued: @issued.map do |cert|
          public_certificate(cert)
        end }
      end
    end
  end

  def new
    @defaults = CsrDefaults.values
  end

  def create
    csr = CsrWorkflow.create(csr_params.to_h, identity: current_identity)
    respond_to do |format|
      format.html { redirect_to certificate_request_path(csr), notice: t("csr.created"), status: :see_other }
      format.json { render json: public_request(csr), status: :created }
    end
  end

  def show
    @certificate = @csr.latest_certificate
    @snapshot = ConsulStore.certid_snapshot(@csr.area, @csr.certid)
    show_response
  rescue ConsulConnection::Error
    @consul_unavailable = true
    show_response
  end

  def download
    CsrAudit.record!("csr_download", @csr, current_identity, outcome: "succeeded")
    send_data @csr.csr_pem, filename: "#{@csr.certid}.csr.pem", type: "application/pkcs10"
  end

  def reveal
    @password = CsrWorkflow.reveal(@csr, identity: current_identity, confirmed: params[:confirm_reveal] == "1")
    respond_to do |format|
      format.html { render :reveal }
      format.json { render json: { revoke_password: @password } }
    end
  end

  def upload
    entry = CsrUpload.call(@csr, data: upload_data, identity: current_identity, replace: params[:confirm_replace] == "1")
    CsrPublication.new(entry, identity: current_identity).call unless entry.state == "awaiting_issuer"
    publication_response(entry)
  end

  def issuers
    entry = @csr.csr_certificates.find(params[:certificate_id])
    CsrUpload.add_issuers(@csr, entry, data: upload_data, identity: current_identity)
    publication_response(entry)
  end

  def publish
    entry = @csr.csr_certificates.find(params[:certificate_id])
    index = params[:certid_index].to_s
    CsrNames.fail!(:confirmation) unless index.match?(/\A\d+\z/)

    CsrPublication.new(entry, identity: current_identity).call(expected_index: index.to_i,
      confirm_overwrite: params[:confirm_overwrite] == "1")
    publication_response(entry)
  end

  private

  def require_csr
    return if current_identity&.any_csr?

    request.format.json? ? render(json: { error: t("csr.errors.forbidden") }, status: :forbidden) : render_error(:forbidden)
  end

  def load_request
    @csr = CertificateRequest.visible_to(current_identity).find(params[:id])
  end

  def csr_params
    params.require(:csr).permit(:area, :certid, :common_name, :sans, :country, :state, :locality, :organization,
      :organizational_unit, :email, :key_algorithm, :key_size, :digest, :comment)
  end

  def upload_data
    file = params[:file]
    data = params[:pem].to_s
    CsrNames.fail!(:format) if file.present? && data.present?

    CsrNames.fail!(:format) if file.present? && !file.respond_to?(:read)

    file.present? ? file.read(Certificates::Codec::MAX_BYTES + 1) : data
  end

  def publication_response(entry)
    respond_to do |format|
      format.html do
        options = entry.state == "published" ? { notice: t("csr.published") } : { alert: t("csr.saved_pending") }
        redirect_to certificate_request_path(@csr), **options, status: :see_other
      end
      format.json do
        render json: public_certificate(entry), status: entry.state == "published" ? :ok : :accepted
      end
    end
  end

  def show_response
    respond_to do |format|
      format.html
      format.json do
        certificates = @csr.csr_certificates.order(:id).map { |cert| public_certificate(cert) }
        render json: public_request(@csr).merge(certid_index: @consul_unavailable ? nil : (@snapshot&.fetch(:index) || 0),
          consul_available: !@consul_unavailable, certificates: certificates)
      end
    end
  end

  def public_request(csr)
    csr.attributes.slice("id", "area", "certid", "common_name", "sans", "subject_fields", "key_algorithm",
      "key_size", "digest", "comment", "created_by", "created_at")
  end

  def public_certificate(cert)
    cert.attributes.slice("id", "certificate_request_id", "subject", "issuer", "fingerprint", "sans",
      "not_before", "not_after", "state", "error_code", "consul_version", "published_at")
  end
end
