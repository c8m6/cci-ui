class EnrichAuditEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :audit_events, :occurred_at, :datetime
    add_column :audit_events, :details, :jsonb, null: false, default: {}
    execute "UPDATE audit_events SET occurred_at = created_at"
    change_column_null :audit_events, :occurred_at, false
    add_index :audit_events, [:area, :occurred_at, :id]
  end

  def down
    remove_index :audit_events, [:area, :occurred_at, :id]
    remove_column :audit_events, :details
    remove_column :audit_events, :occurred_at
  end
end
