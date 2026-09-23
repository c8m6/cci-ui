# frozen_string_literal: true

class AddRolloutStatusToCertificates < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :rollout_status, :string, null: false, default: "active"
    add_check_constraint :certificates, "rollout_status IN ('active', 'norollout', 'delete')",
      name: "certificates_rollout_status"
    add_index :certificates, %i[area rollout_status]
  end
end
