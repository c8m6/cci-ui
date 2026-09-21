class SimplifyCertificateCatalog < ActiveRecord::Migration[8.1]
  def change
    rename_column :certificates, :lookup, :certid
    remove_column :certificates, :entry_id, :string
    add_column :certificates, :certificate_version, :integer
    add_column :certificates, :imported_at, :datetime
    remove_column :audit_events, :store_event_id, :string
  end
end
