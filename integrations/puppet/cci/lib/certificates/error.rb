# frozen_string_literal: true

module Certificates
  # Public certificate error with optional I18n translation and an English fallback.
  class Error < StandardError
    # Keep the certificate utilities usable without Rails or the I18n gem.
    def self.translate(key, default:, **options)
      return I18n.t(key, default: default, **options) if defined?(I18n) && I18n.available_locales.include?(I18n.locale)

      default % options
    end
  end
end
