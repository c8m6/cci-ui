class AddImportDraftsAndConsulAudit < ActiveRecord::Migration[8.1]
  def change
    create_table :import_drafts do |t|
      t.string :token, null: false
      t.string :owner, null: false
      t.text :payload, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :import_drafts, :token, unique: true
    add_index :import_drafts, :expires_at
  end
end
