class AddStoreEventIdToAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :store_event_id, :string
    add_index :audit_events, :store_event_id, unique: true
  end
end
