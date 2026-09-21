require "yaml"
class HieraSnippet
  def self.legacy_dn(name)
    # Match the old application's OpenSSL-style DN formatting and URI escapes.
    safe = /[A-Za-z0-9;,\/:?@&=+$\-_.!~*'()# ]/
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
  def self.for(record, certificate)
    if record.source == "filesystem"
      relative = record.source_id.rpartition("#").first
      tag_path = relative.sub(/\.pem\z/i, ".tag")
      tag = LegacyStore.root(area: record.area).join(tag_path).exist? ? LegacyStore.read(LegacyStore.safe_path(tag_path, area: record.area)).force_encoding("UTF-8").scrub : ""
      { "issuer" => legacy_dn(certificate.issuer), "subject" => legacy_dn(certificate.subject) + tag }.to_yaml
    else
      { "cci::certificates" => { record.certid => { "area" => record.area, "certid" => record.certid,
        "path" => "/etc/ssl/certs/#{record.certid}.pem" } } }.to_yaml
    end
  end
end
