# frozen_string_literal: true

# One source of environment defaults for forms and request validation.
class CsrDefaults
  FIELDS = %w[key_algorithm key_size digest country state locality organization organizational_unit].freeze

  def self.values
    defaults = { "key_algorithm" => "RSA", "key_size" => "4096", "digest" => "SHA512",
                 "country" => "", "state" => "", "locality" => "", "organization" => "", "organizational_unit" => "" }
    FIELDS.to_h { |field| [field, ENV.fetch("CSR_DEFAULT_#{field.upcase}", defaults.fetch(field))] }
  end
end
