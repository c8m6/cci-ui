# frozen_string_literal: true

# Durable CSR workflow with only authenticated ciphertext for secret material.
class CertificateRequest < ApplicationRecord
  has_many :csr_certificates, dependent: :restrict_with_exception
  scope :visible_to, ->(identity) { where(area: identity.csr_areas) }

  def latest_certificate = csr_certificates.order(id: :desc).first
  def secret_context(kind) = "csr:#{secret_id}:#{kind}"
end
