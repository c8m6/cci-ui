# frozen_string_literal: true

class AddAuditActorDisplayName < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :actor_display_name, :text
  end
end
