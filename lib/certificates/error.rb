module Certificates
  class Error < StandardError
    # Keep the certificate utilities usable without Rails or the I18n gem.
    def self.translate(key, default:, **options)
      if defined?(I18n) && I18n.available_locales.include?(I18n.locale)
        return I18n.t(key, default: default, **options)
      end
      default % options
    end
  end
end
