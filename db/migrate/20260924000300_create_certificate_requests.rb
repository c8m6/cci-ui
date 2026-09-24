# frozen_string_literal: true

class CreateCertificateRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :certificate_requests do |t|
      t.string :area, :certid, :created_by, :common_name, null: false
      t.string :secret_id, null: false
      t.text :csr_pem, :encrypted_private_key, :encrypted_revoke_password, null: false
      t.jsonb :sans, default: [], null: false
      t.jsonb :subject_fields, default: {}, null: false
      t.string :key_algorithm, :digest, null: false
      t.integer :key_size, null: false
      t.text :comment, null: false, default: ""
      t.timestamps
    end
    add_index :certificate_requests, :secret_id, unique: true
    add_index :certificate_requests, %i[area created_at]

    create_table :csr_certificates do |t|
      t.references :certificate_request, null: false, foreign_key: true
      t.text :pem, :subject, :issuer, null: false
      t.string :fingerprint, :uploaded_by, null: false
      t.jsonb :sans, :issuer_pems, default: [], null: false
      t.datetime :not_before, :not_after, null: false
      t.string :state, null: false, default: "awaiting_issuer"
      t.string :error_code
      t.jsonb :prepared, default: {}, null: false
      t.integer :consul_version
      t.datetime :verified_at, :published_at
      t.timestamps
    end
    add_index :csr_certificates, %i[certificate_request_id fingerprint], unique: true
    add_check_constraint :csr_certificates,
      "state IN ('awaiting_issuer', 'pending', 'publishing', 'published', 'failed')", name: "csr_certificate_state"
    add_check_constraint :csr_certificates,
      "state <> 'published' OR (consul_version > 0 AND published_at IS NOT NULL)", name: "csr_published_version"
  end
end
