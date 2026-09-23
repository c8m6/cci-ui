# frozen_string_literal: true

require "openssl"
require "base64"
require "json"
require_relative "error"
require_relative "../area_configuration"
require_relative "../area_secrets"

module Certificates
  # Versioned AES-GCM envelopes shared by Rails and standalone integrations.
  # Authenticated context prevents moving ciphertext between areas or versions.
  class Vault
    def self.key(area)
      unless AreaConfiguration.ids.include?(area)
        raise Error,
          Error.translate("errors.app.unknown_area",
            default: "Unknown area.")
      end

      encoded = AreaSecrets.fetch(area)
      key = Base64.strict_decode64(encoded)
      raise ArgumentError unless key.bytesize == 32

      key
    rescue ArgumentError
      raise Error,
        Error.translate("errors.app.area_secret",
          default: "A valid encryption secret (32 bytes, Base64) is missing for %{area}.", area: AreaConfiguration.label(area))
    end

    # Explicit Base64 keys let standalone clients operate without Rails area configuration.
    def self.encryption_key(area, encoded)
      return key(area) unless encoded

      decoded = Base64.strict_decode64(encoded)
      raise ArgumentError, "Area key must contain 32 bytes" unless decoded.bytesize == 32

      decoded
    end

    # The returned JSON is the persisted version-1 envelope, not a PEM wrapper.
    def self.encrypt(pem, area:, id:, encryption_key: nil)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = self.encryption_key(area, encryption_key)
      iv = cipher.random_iv
      cipher.auth_data = "cci:#{area}:#{id}"
      encrypted = cipher.update(pem) + cipher.final
      JSON.generate(version: 1, iv: Base64.strict_encode64(iv), tag: Base64.strict_encode64(cipher.auth_tag),
        data: Base64.strict_encode64(encrypted))
    end

    def self.decrypt(envelope, area:, id:, encryption_key: nil)
      data = JSON.parse(envelope)
      unless data.fetch("version") == 1
        raise Error,
          Error.translate("errors.app.key_version", default: "Unknown key version.")
      end

      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = self.encryption_key(area, encryption_key)
      cipher.iv = Base64.strict_decode64(data.fetch("iv"))
      cipher.auth_tag = Base64.strict_decode64(data.fetch("tag"))
      cipher.auth_data = "cci:#{area}:#{id}"
      cipher.update(Base64.strict_decode64(data.fetch("data"))) + cipher.final
    rescue OpenSSL::OpenSSLError, JSON::ParserError, KeyError, ArgumentError
      raise Error, Error.translate("errors.app.key_decrypt", default: "The private key could not be decrypted.")
    end
  end
end
