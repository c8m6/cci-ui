# frozen_string_literal: true

require "ipaddr"

# Canonical TLS identities without interpreting user input as OpenSSL configuration.
class CsrNames
  def self.fail!(code)
    raise Certificates::Error, I18n.t("csr.errors.#{code}")
  end

  def self.name(value)
    value = value.to_s.strip
    fail!(:names) if value.empty? || value.include?("/") || value.match?(/[\s\x00-\x1f]/)

    begin
      return "IP:#{IPAddr.new(value)}"
    rescue IPAddr::InvalidAddressError
      # DNS and leftmost wildcard DNS names are checked label by label.
    end
    dns = value.downcase.delete_suffix(".")
    labels = dns.delete_prefix("*.").split(".", -1)
    valid = dns.bytesize <= 253 && labels.all? do |label|
      label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
    end
    fail!(:names) unless valid && labels.any? && !dns.match?(/\A[0-9.]+\z/)

    "DNS:#{dns}"
  end

  def self.sans(common_name, input)
    values = input.to_s.split(/[\s,;]+/).reject(&:empty?)
    fail!(:names) if values.size > 100

    ([name(common_name)] + values.map { |value| san(value) }).uniq.sort
  end

  def self.san(value)
    type, rest = value.split(":", 2)
    return name(value) unless %w[DNS IP].include?(type.upcase)

    result = name(rest)
    fail!(:names) unless result.start_with?("#{type.upcase}:")

    result
  end

  def self.certificate_sans(cert)
    extensions = cert.extensions.select { |extension| extension.oid == "subjectAltName" }
    fail!(:mismatch) unless extensions.size == 1

    sequence = OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(extensions.first.to_der).value.last.value)
    sequence.value.map do |entry|
      case entry.tag
      when 2 then san("DNS:#{entry.value}")
      when 7 then "IP:#{IPAddr.new_ntoh(entry.value)}"
      else fail!(:mismatch)
      end
    end.sort
  rescue OpenSSL::ASN1::ASN1Error, IPAddr::InvalidAddressError
    fail!(:mismatch)
  end
end
