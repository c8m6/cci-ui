# frozen_string_literal: true

# A matching issued certificate and its durable publication intent.
class CsrCertificate < ApplicationRecord
  belongs_to :certificate_request
end
