require "openssl"
require "base64"
require "json"
require_relative "../area_configuration"
require_relative "../area_secrets"

module Certificates
  class Vault
    def self.key(area)
      raise Error, Error.translate("errors.app.unknown_area", default: "Unbekannter Bereich.") unless AreaConfiguration.ids.include?(area)
      encoded = AreaSecrets.fetch(area)
      key = Base64.strict_decode64(encoded)
      raise ArgumentError unless key.bytesize == 32
      key
    rescue ArgumentError
      raise Error, Error.translate("errors.app.area_secret", default: "Für %{area} fehlt ein gültiges Verschlüsselungs-Secret (32 Byte, Base64).", area: AreaConfiguration.label(area))
    end

    def self.encrypt(pem, area:, id:)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = key(area)
      iv = cipher.random_iv
      cipher.auth_data = "cci:v1:#{area}:#{id}"
      encrypted = cipher.update(pem) + cipher.final
      JSON.generate(version: 1, iv: Base64.strict_encode64(iv), tag: Base64.strict_encode64(cipher.auth_tag), data: Base64.strict_encode64(encrypted))
    end

    def self.decrypt(envelope, area:, id:)
      data = JSON.parse(envelope)
      raise Error, Error.translate("errors.app.key_version", default: "Unbekannte Schlüsselversion.") unless data.fetch("version") == 1
      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = key(area)
      cipher.iv = Base64.strict_decode64(data.fetch("iv"))
      cipher.auth_tag = Base64.strict_decode64(data.fetch("tag"))
      cipher.auth_data = "cci:v1:#{area}:#{id}"
      cipher.update(Base64.strict_decode64(data.fetch("data"))) + cipher.final
    rescue OpenSSL::OpenSSLError, JSON::ParserError, KeyError, ArgumentError
      raise Error, Error.translate("errors.app.key_decrypt", default: "Privater Schlüssel konnte nicht entschlüsselt werden.")
    end
  end
end
