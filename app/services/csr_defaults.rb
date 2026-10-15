# frozen_string_literal: true

# One source of defaults for forms and request validation.
class CsrDefaults
  FIELDS = %w[key_algorithm key_size digest country state locality organization organizational_unit].freeze

  def self.values = CciConfiguration.current.dig("csr", "defaults").transform_values(&:to_s)
end
