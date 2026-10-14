# frozen_string_literal: true

# Displays cached observations within the same area permissions as certificate pages.
class HostsController < ApplicationController
  before_action :require_puppetdb

  def index
    @inventory = PuppetdbHosts.new(current_identity, area: params[:area]).list(
      query: params[:q], sync: params[:sync], page: params[:page]
    )
  end

  def show
    @certname = PuppetdbHosts.certname(params[:id])
    inventory = PuppetdbHosts.new(current_identity)
    @summary = inventory.summary(@certname)
    @pages = [(@summary.fetch(:total) / 30.0).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @pages)
    @certificates = inventory.certificates(@certname).order(:area, :common_name, :id).offset((@page - 1) * 30).limit(30)
  end

  private

  def require_puppetdb
    render_error(:not_found) unless PuppetdbConfiguration.enabled?
  end
end
