require_relative "consul_connection"
require "openssl"
require "base64"
require "json"

# One instance per Puppet compile. Canonical PEM output is deterministic so
# Puppet's native File resource compares content without reissuing certificates.
class CciClient
  class Error < StandardError; end
  def initialize(url:, token: "", keys: {}, prefix: "cci/v1", connection: nil)
    @connection = connection || ConsulConnection.new(url: url, token: token)
    @keys, @prefix, @cache = keys, prefix, {}
  end
  def fetch(area:, lookup:, field: "certificate", version: nil)
    raise Error, "Invalid area" unless area.is_a?(String) && area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    raise Error, "Invalid lookup" unless lookup.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise Error, "Unknown field" unless %w[certificate chain private_key metadata].include?(field)
    raise Error, "Invalid version" if version && !version.match?(/\A[0-9a-f]{64}\z/)
    base = "#{@prefix}/areas/#{area}"
    material = @cache[[area, lookup, version]] ||= begin
      entry = JSON.parse((@connection.get("#{base}/lookups/#{lookup}") || raise(Error, "Lookup not found"))[:value])
      id = version || entry.fetch("active_version")
      data = JSON.parse((@connection.get("#{base}/versions/#{id}") || raise(Error, "Version not found"))[:value])
      raise Error, "Version not found for this entry" unless data["entry_id"] == entry["entry_id"] && data["schema"] == "1"
      data.merge("version_id" => id)
    end
    cert = OpenSSL::X509::Certificate.new(material.fetch("pem"))
    raise Error, "Certificate fingerprint mismatch" unless Digest::SHA256.hexdigest(cert.to_der) == material.fetch("fingerprint")
    case field
    when "metadata" then material.slice("version_id", "fingerprint", "public_key_fingerprint", "has_key")
    when "certificate" then cert.to_pem
    when "chain" then [cert.to_pem, *JSON.parse(material.fetch("chain")).map { |pem| OpenSSL::X509::Certificate.new(pem).to_pem }].join
    when "private_key"
      material["decrypted_key"] ||= begin
        id = material.fetch("version_id")
        raw = @connection.get("#{base}/private-keys/#{id}") || raise(Error, "Private key not available")
        data = JSON.parse(raw[:value])
        raise Error, "Unsupported encryption version" unless data.fetch("version") == 1
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = Base64.strict_decode64(@keys.fetch(area))
        cipher.iv = Base64.strict_decode64(data.fetch("iv"))
        cipher.auth_tag = Base64.strict_decode64(data.fetch("tag"))
        cipher.auth_data = "cci:v1:#{area}:#{id}"
        key = OpenSSL::PKey.read(cipher.update(Base64.strict_decode64(data.fetch("data"))) + cipher.final)
        raise Error, "Certificate and key do not match" unless cert.check_private_key(key)
        key.private_to_pem
      end
    end
  rescue ConsulConnection::Error, OpenSSL::OpenSSLError, KeyError, ArgumentError, JSON::ParserError
    raise Error, "Certificate lookup failed (connection, format or key configuration)"
  end
end
