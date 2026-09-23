# frozen_string_literal: true

class AddSha1FingerprintsToCertificates < ActiveRecord::Migration[8.1]
  def change
    add_column :certificates, :sha1_fingerprint, :string
    add_index :certificates, :sha1_fingerprint
  end
end
