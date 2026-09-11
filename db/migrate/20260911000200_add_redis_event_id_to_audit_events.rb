class AddRedisEventIdToAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :redis_event_id, :string
    add_index :audit_events, :redis_event_id, unique: true
  end
end
