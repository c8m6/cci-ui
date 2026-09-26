# frozen_string_literal: true

# Durable CSR workflow with one shared request and one or more publication areas.
class CertificateRequest < ApplicationRecord
  has_many :csr_certificates, dependent: :restrict_with_exception
  scope :visible_to, lambda { |identity|
    where("target_areas <@ ?::jsonb", identity.csr_areas.to_json)
  }

  before_validation do
    self.target_areas = [area] if target_areas.blank? && area.present?
  end
  validate do
    normalized = Array(target_areas).grep(String).uniq
    errors.add(:target_areas, :invalid) if normalized.empty? || normalized != target_areas ||
                                           (normalized - AreaConfiguration.ids).any? || normalized.first != area
  end

  def latest_certificate = csr_certificates.order(id: :desc).first
  def secret_context(kind) = "csr:#{secret_id}:#{kind}"
  def areas = target_areas.presence || [area]
end
