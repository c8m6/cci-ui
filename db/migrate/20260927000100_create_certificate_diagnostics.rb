# frozen_string_literal: true

class CreateCertificateDiagnostics < ActiveRecord::Migration[8.1]
  def change
    create_table :certificate_diagnostic_results do |table|
      table.string :area, :fingerprint, :check_id, null: false
      table.string :input_version, :data_version
      table.string :state, null: false, default: "pending"
      table.string :reason, :last_error
      table.datetime :checked_at, :expires_at, :last_attempt_at, :revoked_at
      table.datetime :next_due_at, null: false
      table.integer :failures, null: false, default: 0
      table.boolean :suspended, null: false, default: false
      table.boolean :priority, null: false, default: false
      table.jsonb :details, null: false, default: {}
      table.timestamps
    end
    add_index :certificate_diagnostic_results, %i[area fingerprint check_id], unique: true, name: "diagnostic_identity"
    add_index :certificate_diagnostic_results, %i[suspended next_due_at], name: "diagnostic_due"

    create_table :certificate_diagnostic_caches do |table|
      table.string :cache_id, null: false
      table.binary :payload
      table.jsonb :metadata, null: false, default: {}
      table.datetime :expires_at, :lease_until
      table.string :lease_token
      table.timestamps
    end
    add_index :certificate_diagnostic_caches, :cache_id, unique: true
  end
end
