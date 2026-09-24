# frozen_string_literal: true

# Presents cached CA references without crossing the current identity's area scope.
class CaInventoriesController < ApplicationController
  before_action :require_ca_inventory

  def index
    @inventories = CaInventory.where(area: current_identity.areas).index_by(&:area)
  end

  def show
    inventory = CaInventory.where(area: current_identity.areas).find_by!(area: params[:id])
    send_data inventory.hiera, filename: "ca-certificates-#{inventory.area}.yaml", type: "application/yaml"
  end

  private

  def require_ca_inventory
    render_error(:not_found) unless CaInventory.enabled?
  end
end
