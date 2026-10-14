# frozen_string_literal: true

# Presents cached CA references without crossing the current identity's area scope.
class CaInventoriesController < ApplicationController
  def show
    inventory = CaInventory.where(area: current_identity.areas).find_by!(area: params[:id])
    send_data inventory.hiera, filename: "ca-certificates-#{inventory.area}.yaml", type: "application/yaml"
  end
end
