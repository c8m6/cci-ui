class ImportsController < ApplicationController
  def new
    return head :forbidden unless current_identity.any_writer?
  end
  def create
    if params[:token].present?
      successes, @errors = CertificateImport.commit(token: params[:token], owner: session[:import_owner], identity: current_identity)
      return redirect_to root_path, notice: "#{successes.size} Zertifikate gespeichert.", status: :see_other if @errors.empty?
      flash.now[:alert] = "#{successes.size} Zertifikate gespeichert. Einige Einträge konnten nicht gespeichert werden."
      render :new, status: :unprocessable_entity
    else
      areas = Array(params[:areas]).reject(&:blank?).uniq
      areas.each { |area| require_writer!(area) }
      @token, @preview = CertificateImport.preview(files: Array(params[:files]).reject(&:blank?), pem: params[:pem].to_s,
        password: params[:password].to_s, areas: areas, tags: params[:tags].to_s, lookup: params[:lookup].to_s,
        owner: session[:import_owner])
      render :preview
    end
  end
end
