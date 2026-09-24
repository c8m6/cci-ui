# frozen_string_literal: true

require "yaml"
# Produces Puppet references while retaining legacy distinguished-name encoding.
class HieraSnippet
  def self.legacy_dn(name)
    # Match the old application's OpenSSL-style DN formatting and URI escapes.
    safe = %r{[A-Za-z0-9;,/:?@&=+$\-_.!~*'()# ]}
    name.to_a.map do |key, value, _type|
      # OpenSSL returns ASN.1 value bytes as ASCII-8BIT, including UTF-8 text.
      # Preserve those bytes in the legacy escapes instead of transcoding them.
      encoded = value.bytes.map do |byte|
        character = byte.chr
        character.match?(safe) ? character : format("\\x%02X", byte)
      end.join
      "#{key}=#{encoded}"
    end.join(", ").gsub(/, (serialNumber|postalCode|emailAddress)=/, '/\1=')
  end

  def self.reference(record, certificate)
    return { "lookup" => record.certid } if record.source == "consul"

    relative = record.source_id.rpartition("#").first
    tag_path = relative.sub(/\.pem\z/i, ".tag")
    tag = if LegacyStore.root(area: record.area).join(tag_path).exist?
            LegacyStore.read(LegacyStore.safe_path(
              tag_path, area: record.area
            )).force_encoding("UTF-8").scrub
          else
            ""
          end
    { "issuer" => legacy_dn(certificate.issuer), "subject" => legacy_dn(certificate.subject) + tag }
  end

  def self.for(record, certificate)
    values = reference(record, certificate)
    return values.to_yaml if record.source == "filesystem"

    { "cci::certificates" => { record.certid => values.merge("area" => record.area,
      "path" => "/etc/ssl/certs/#{record.certid}.pem") } }.to_yaml
  end
end
