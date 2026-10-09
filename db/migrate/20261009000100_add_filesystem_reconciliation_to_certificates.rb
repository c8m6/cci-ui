# frozen_string_literal: true

class AddFilesystemReconciliationToCertificates < ActiveRecord::Migration[8.1]
  def change
    # Existing unobserved rows remain unassigned and cannot authorize cleanup.
    add_column :certificates, :filesystem_source_path, :text
    add_column :certificates, :filesystem_missing_scans, :integer, default: 0, null: false
    add_column :certificates, :filesystem_cleanup_blocked, :boolean, default: false, null: false
    add_check_constraint :certificates, "filesystem_missing_scans >= 0", name: "filesystem_missing_scans_nonnegative"
  end
end
