# frozen_string_literal: true

class AddCertificateArchiving < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :archived, :boolean, default: false, null: false
    add_index :certificates, %i[area archived active]
    remove_index :certificates, %i[area source source_id], unique: true
    add_index :certificates, %i[area source source_id fingerprint], unique: true,
      name: "index_certificates_on_source_identity_and_fingerprint"
    add_check_constraint :certificates, "NOT archived OR rollout_status = 'delete'",
      name: "archived_certificates_request_deletion"
  end
end
