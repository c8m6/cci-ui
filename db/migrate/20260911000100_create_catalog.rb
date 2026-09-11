class CreateCatalog < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    create_table :certificates do |t|
      t.string :area, null: false
      t.string :source, null: false
      t.string :source_id, null: false
      t.string :entry_id
      t.string :lookup
      t.string :common_name, null: false
      t.text :subject, null: false
      t.text :issuer, null: false
      t.string :serial, null: false
      t.string :fingerprint, null: false
      t.string :algorithm
      t.jsonb :sans, null: false, default: []
      t.jsonb :tags, null: false, default: []
      t.boolean :has_key, null: false, default: false
      t.boolean :active, null: false, default: true
      t.datetime :not_before, null: false
      t.datetime :not_after, null: false
      t.datetime :indexed_at, null: false
      t.text :search_text, null: false
      t.timestamps
    end
    add_index :certificates, %i[area source source_id], unique: true
    add_index :certificates, %i[area active not_after]
    add_index :certificates, :fingerprint
    add_index :certificates, :entry_id
    add_index :certificates, :search_text, using: :gin, opclass: :gin_trgm_ops
    create_table :audit_events do |t|
      t.string :actor, null: false
      t.string :action, null: false
      t.string :area, null: false
      t.jsonb :references, null: false, default: []
      t.timestamps
    end
  end
end
