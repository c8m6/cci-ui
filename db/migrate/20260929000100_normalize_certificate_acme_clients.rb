# frozen_string_literal: true

class NormalizeCertificateAcmeClients < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE certificates SET client = 'puppet'
      WHERE lower(client) ~ '(^|[_.-])acme([_.-]|$)'
    SQL
    add_check_constraint :certificates,
      "client IS NULL OR lower(client) !~ '(^|[_.-])acme([_.-]|$)'",
      name: "certificates_no_acme_client"
  end

  def down
    # Removing the constraint permits an older application to run. Do not invent
    # the original client names or revert valid Puppet ownership to ACME.
    remove_check_constraint :certificates, name: "certificates_no_acme_client"
  end
end
