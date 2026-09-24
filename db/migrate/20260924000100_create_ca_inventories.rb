# frozen_string_literal: true

class CreateCaInventories < ActiveRecord::Migration[8.1]
  def change
    create_table :ca_inventories do |t|
      t.string :area, null: false
      t.jsonb :authorities, null: false, default: []
      t.jsonb :issues, null: false, default: []
      t.datetime :checked_at
      t.datetime :error_at
      t.timestamps
    end
    add_index :ca_inventories, :area, unique: true
  end
end
