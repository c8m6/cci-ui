class DisableFilesystemControlState < ActiveRecord::Migration[8.1]
  def up
    # Only reset the obsolete local projection. Keep certificates, historical
    # Consul metadata and audit events; filesystem sources are always read-only.
    execute "UPDATE certificates SET archived = FALSE, rollout_status = 'active' WHERE source = 'filesystem'"
    add_check_constraint :certificates,
      "source <> 'filesystem' OR (NOT archived AND rollout_status = 'active')",
      name: "filesystem_certificates_have_no_control_state"
  end

  def down
    remove_check_constraint :certificates, name: "filesystem_certificates_have_no_control_state"
  end
end
