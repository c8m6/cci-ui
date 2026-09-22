require_relative "consul_connection"
require "digest"

# One instance per operation or Puppet compile. Supplying an area key opts in to
# retrieving the encrypted private key together with the public certificate.
class CciClient
  class Error < StandardError; end
  def initialize(url:, token: "", keys: {}, prefix: "cci", connection: nil)
    @connection = connection || ConsulConnection.new(url: url, token: token)
    @keys, @prefix, @cache, @candidates = keys, prefix, {}, {}
  end

  def fetch(area:, certid:, field: "certificate", version: nil)
    raise Error, "Invalid area" unless area.is_a?(String) && area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    raise Error, "Invalid certid" unless certid.is_a?(String) && certid.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise Error, "Unknown field" unless %w[certificate chain private_key metadata].include?(field)
    raise Error, "Invalid version" if version && (!version.is_a?(Integer) || version < 1)
    base = "#{@prefix}/#{area}"
    material = @cache[[area, certid, version]] ||= begin
      entry = JSON.parse((@connection.get("#{base}/certids/#{certid}") || raise(Error, "CertID not found"))[:value])
      selected = version || entry.fetch("active_version")
      raise Error, "Invalid active version" unless selected.is_a?(Integer) && selected.positive?
      status = entry.fetch("status", "active")
      raise Error, "Invalid rollout status" unless %w[active norollout delete].include?(status)
      public_path = "#{base}/certs/#{certid}/#{selected}"
      private_path = "#{base}/keys/#{certid}/#{selected}"
      # get-or-empty keeps a public-only version readable with key access enabled.
      if @keys.key?(area)
        result = @connection.transaction([
          { "Verb" => "get", "Key" => public_path },
          { "Verb" => "get-or-empty", "Key" => private_path }
        ])
        values = result.fetch("Results").to_h { |item| [item.fetch("KV").fetch("Key"), item.fetch("KV")["Value"]] }
        data = JSON.parse(Base64.strict_decode64(values.fetch(public_path)))
        data["envelope"] = Base64.strict_decode64(values[private_path]) if values[private_path]
      else
        data = JSON.parse((@connection.get(public_path) || raise(Error, "Version not found"))[:value])
      end
      data.merge("version" => selected, "certid" => certid, "status" => status)
    end
    cert = OpenSSL::X509::Certificate.new(material.fetch("pem"))
    case field
    when "metadata"
      material.slice("certid", "status", "version", "has_key", "client", "created_by", "created_at", "tags").merge(
        "fingerprint" => Digest::SHA256.hexdigest(cert.to_der),
        "public_key_fingerprint" => Digest::SHA256.hexdigest(cert.public_key.public_to_der))
    when "certificate" then cert.to_pem
    when "chain" then build_chain(area, cert).map(&:to_pem).join
    when "private_key"
      material["decrypted_key"] ||= begin
        raise Error, "Private key access was not configured" unless @keys.key?(area)
        data = JSON.parse(material.fetch("envelope") { raise Error, "Private key not available" })
        raise Error, "Unsupported encryption version" unless data.fetch("version") == 1
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = Base64.strict_decode64(@keys.fetch(area))
        cipher.iv = Base64.strict_decode64(data.fetch("iv"))
        cipher.auth_tag = Base64.strict_decode64(data.fetch("tag"))
        cipher.auth_data = "cci:#{area}:#{certid}/#{material.fetch('version')}"
        key = OpenSSL::PKey.read(cipher.update(Base64.strict_decode64(data.fetch("data"))) + cipher.final)
        raise Error, "Certificate and key do not match" unless cert.check_private_key(key)
        key.private_to_pem
      end
    end
  rescue ConsulConnection::Error, OpenSSL::OpenSSLError, KeyError, ArgumentError, JSON::ParserError, TypeError
    raise Error, "Certificate read failed (connection, format or key configuration)"
  end

  # Chain discovery is explicitly outside the two-request material read. Every
  # stored certificate is independent; only public material in this area is read.
  def build_chain(area, leaf)
    return [leaf] if leaf.subject == leaf.issuer && leaf.verify(leaf.public_key)
    candidates = @candidates[area] ||= @connection.all("#{@prefix}/#{area}/certs/").map do |item|
      OpenSSL::X509::Certificate.new(JSON.parse(item.fetch(:value)).fetch("pem"))
    end
    chain = [leaf]
    seen = { Digest::SHA256.hexdigest(leaf.to_der) => true }
    12.times do
      current = chain.last
      break if current.subject == current.issuer && current.verify(current.public_key)
      parent = candidates.find do |candidate|
        !seen[Digest::SHA256.hexdigest(candidate.to_der)] && candidate.subject == current.issuer &&
          candidate.extensions.any? { |extension| extension.oid == "basicConstraints" && extension.value.include?("CA:TRUE") } &&
          current.verify(candidate.public_key)
      end
      break unless parent
      chain << parent
      seen[Digest::SHA256.hexdigest(parent.to_der)] = true
    end
    chain
  end
end
