class AddCertificateProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :client, :string
    add_column :certificates, :created_by, :string
  end
end
