# frozen_string_literal: true

class AddCsrTargetAreas < ActiveRecord::Migration[8.1]
  def up
    add_column :certificate_requests, :target_areas, :jsonb, default: [], null: false
    add_column :csr_certificates, :consul_versions, :jsonb, default: {}, null: false
    execute "UPDATE certificate_requests SET target_areas = jsonb_build_array(area) WHERE target_areas = '[]'::jsonb"
    add_index :certificate_requests, :target_areas, using: :gin
  end

  def down
    remove_index :certificate_requests, :target_areas
    remove_column :csr_certificates, :consul_versions
    remove_column :certificate_requests, :target_areas
  end
end
