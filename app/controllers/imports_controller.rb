class ImportsController < ApplicationController
  rescue_from Certificates::Error do |error|
    Rails.logger.error(error.full_message(highlight: false))
    # A preview can expire or be consumed. Redirecting back to its URL would
    # repeat the same failure, so always return to a usable page.
    destination = current_identity&.any_writer? ? new_import_path : root_path
    redirect_to destination, alert: error.message, status: :see_other
  end

  def new
    return render_error(:forbidden) unless current_identity.any_writer?
  end

  # Reopen an existing preview after a language change without repeating upload
  # processing or consuming the draft. The original owner and expiry still apply.
  def preview
    @token = params[:token].to_s
    draft = ImportDraft.find_by(token: @token, owner: session[:import_owner])
    raise Certificates::Error, I18n.t("errors.app.expired_preview") unless draft && draft.expires_at > Time.current
    @preview = JSON.parse(draft.payload)
    @preview.fetch("areas").each { |area| require_writer!(area) }
  end
  def create
    if params[:token].present?
      successes, @errors = CertificateImport.commit(token: params[:token], owner: session[:import_owner], identity: current_identity, confirm_overwrite: params[:confirm_overwrite] == "1")
      return redirect_to root_path, notice: I18n.t("notices.imported", count: successes.size), status: :see_other if @errors.empty?
      flash.now[:alert] = I18n.t("notices.partial_import", count: successes.size)
      render :new, status: :unprocessable_content
    else
      areas = Array(params[:areas]).reject(&:blank?).uniq
      areas.each { |area| require_writer!(area) }
      @token, @preview = CertificateImport.preview(files: Array(params[:files]).reject(&:blank?), pem: params[:pem].to_s,
        password: params[:password].to_s, areas: areas, tags: params[:tags].to_s, certid: params[:certid].to_s,
        owner: session[:import_owner])
      render :preview
    end
  rescue CertificateImport::ConfirmationRequired => error
    @token, @preview = params[:token], error.preview
    flash.now[:alert] = error.message
    render :preview, status: :unprocessable_content
  end
end
