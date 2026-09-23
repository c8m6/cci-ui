# frozen_string_literal: true

require_relative "consul_connection"
require_relative "certificates/vault"
require "digest"

# One instance per operation or Puppet compile. Supplying an area key opts in to
# retrieving the encrypted private key together with the public certificate.
class CciClient
  # Public error boundary hides transport responses and private material.
  class Error < StandardError; end

  # Operational limit, not an X.509 rule: at most twelve issuer hops per leaf.
  # This bounds signature checks for malformed or excessively long inventories.
  MAX_CHAIN_ISSUERS = 12

  def initialize(url:, token: "", keys: {}, prefix: "cci", connection: nil)
    @connection = connection || ConsulConnection.new(url: url, token: token)
    @keys = keys
    @prefix = prefix
    @cache = {}
    @candidates = {}
  end

  # Read one field from a version pinned for this client instance. Omit version
  # to select the active version on first access, then reuse it for later fields.
  def read_certificate(area:, certid:, field: "certificate", version: nil)
    validate_selection(area, certid, field, version)

    material = @cache[[area, certid, version]] ||= load_material(area, certid, version)
    cert = OpenSSL::X509::Certificate.new(material.fetch("pem"))
    case field
    when "metadata"
      material.slice("certid", "status", "version", "has_key", "client", "created_by", "created_at", "tags").merge(
        "fingerprint" => Digest::SHA256.hexdigest(cert.to_der),
        "public_key_fingerprint" => Digest::SHA256.hexdigest(cert.public_key.public_to_der)
      )
    when "certificate" then cert.to_pem
    when "chain" then build_chain(area, cert).map(&:to_pem).join
    when "private_key"
      material["decrypted_key"] ||= decrypt_private_key(material, area, certid, cert)
    end
  rescue Certificates::Error, ConsulConnection::Error, OpenSSL::OpenSSLError, KeyError, ArgumentError,
    JSON::ParserError, TypeError
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
    MAX_CHAIN_ISSUERS.times do
      current = chain.last
      break if current.subject == current.issuer && current.verify(current.public_key)

      parent = candidates.find do |candidate|
        !seen[Digest::SHA256.hexdigest(candidate.to_der)] && issuer?(candidate, current)
      end
      break unless parent

      chain << parent
      seen[Digest::SHA256.hexdigest(parent.to_der)] = true
    end
    chain
  end

  private

  # Resolve the mutable pointer once, then read immutable version paths.
  def load_material(area, certid, version)
    base = "#{@prefix}/#{area}"
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

  # Reject malformed paths and selectors before making network requests.
  def validate_selection(area, certid, field, version)
    raise Error, "Invalid area" unless area.is_a?(String) && area.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    raise Error, "Invalid certid" unless certid.is_a?(String) && certid.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)
    raise Error, "Unknown field" unless %w[certificate chain private_key metadata].include?(field)
    raise Error, "Invalid version" if version && (!version.is_a?(Integer) || version < 1)
  end

  # Vault checks the authenticated area/version context before key matching.
  def decrypt_private_key(material, area, certid, cert)
    raise Error, "Private key access was not configured" unless @keys.key?(area)

    envelope = material.fetch("envelope") { raise Error, "Private key not available" }
    pem = Certificates::Vault.decrypt(envelope, area: area, id: "#{certid}/#{material.fetch("version")}",
      encryption_key: @keys.fetch(area))
    key = OpenSSL::PKey.read(pem)
    raise Error, "Certificate and key do not match" unless cert.check_private_key(key)

    key.private_to_pem
  end

  # An issuer must be a CA and verify the child, not merely share its name.
  def issuer?(candidate, certificate)
    candidate.subject == certificate.issuer &&
      candidate.extensions.any? { |extension| extension.oid == "basicConstraints" && extension.value.include?("CA:TRUE") } &&
      certificate.verify(candidate.public_key)
  end
end
