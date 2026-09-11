require "yaml"
class HieraSnippet
  def self.legacy_dn(name)
    # Match the old application's OpenSSL-style DN formatting and URI escapes.
    safe = /[A-Za-z0-9;,\/:?@&=+$\-_.!~*'()# ]/
    name.to_a.map do |key, value, _type|
      encoded = value.encode("UTF-8").bytes.map do |byte|
        character = byte.chr
        character.match?(safe) ? character : format("\\x%02X", byte)
      end.join
      "#{key}=#{encoded}"
    end.join(", ").gsub(/, (serialNumber|postalCode|emailAddress)=/, '/\1=')
  end
  def self.for(record, certificate)
    if record.source == "filesystem"
      relative = record.source_id.rpartition("#").first
      tag_path = relative.sub(/\.pem\z/, ".tag")
      tag = LegacyStore.root.join(tag_path).exist? ? LegacyStore.read(LegacyStore.safe_path(tag_path)).force_encoding("UTF-8").scrub : ""
      { "issuer" => legacy_dn(certificate.issuer), "subject" => legacy_dn(certificate.subject) + tag }.to_yaml
    else
      { "cci::certificates" => { record.lookup => { "area" => record.area, "lookup" => record.lookup,
        "path" => "/etc/ssl/certs/#{record.lookup}.pem" } } }.to_yaml
    end
  end
end
