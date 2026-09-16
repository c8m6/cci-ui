class AddPuppetdbHostsToCertificates < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :puppetdb_hosts, :jsonb, default: [], null: false
    add_column :certificates, :puppetdb_checked_at, :datetime
    add_column :certificates, :puppetdb_error_at, :datetime
    add_check_constraint :certificates, "jsonb_typeof(puppetdb_hosts) = 'array'",
      name: "certificate_puppetdb_hosts_are_array"
  end
end
