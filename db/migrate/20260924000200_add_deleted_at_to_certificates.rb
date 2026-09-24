# frozen_string_literal: true

# Retain filesystem deletion tombstones independently of Consul rollout state.
class AddDeletedAtToCertificates < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :deleted_at, :datetime
    add_index :certificates, :deleted_at
  end
end
