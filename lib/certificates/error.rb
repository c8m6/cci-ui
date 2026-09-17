module Certificates
  class Error < StandardError
    # Keep the certificate utilities usable without Rails or the I18n gem.
    def self.translate(key, default:, **options)
      return I18n.t(key, default: default, **options) if defined?(I18n)
      default % options
    end
  end
end
