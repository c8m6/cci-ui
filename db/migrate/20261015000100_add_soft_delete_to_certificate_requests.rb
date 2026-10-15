# frozen_string_literal: true

class AddSoftDeleteToCertificateRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :certificate_requests, :deleted_at, :datetime
    add_column :certificate_requests, :deleted_by, :string
    add_index :certificate_requests, :deleted_at
  end
end
