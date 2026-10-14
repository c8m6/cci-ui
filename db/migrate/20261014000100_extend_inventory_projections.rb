# frozen_string_literal: true

class ExtendInventoryProjections < ActiveRecord::Migration[8.1]
  def change
    add_column :ca_inventories, :issuer_edges, :jsonb, default: {}, null: false
    add_column :certificates, :puppetdb_paths, :jsonb, default: {}, null: false
  end
end
