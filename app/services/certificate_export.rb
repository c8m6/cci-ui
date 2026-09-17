require "zip"
class CertificateExport
  FORMATS = %w[pem der p12 jks].freeze
  def self.call(records, identity:, format:, include_key:, include_chain:, password:, source_password: "")
    raise Certificates::Error, I18n.t("errors.app.unknown_export") unless FORMATS.include?(format)
    raise Certificates::Error, I18n.t("errors.app.export_count") unless (1..100).cover?(records.size)
    raise Certificates::Error, I18n.t("errors.app.reader_export") if records.any? { |record| !identity.export?(record.area) }
    if include_key && records.any? { |record| !identity.export_key?(record.area) }
      raise Certificates::Error, I18n.t("errors.app.key_export_role")
    end
    raise Certificates::Error, I18n.t("errors.app.export_password") if (include_key || %w[p12 jks].include?(format)) && password.length < 12
    raise Certificates::Error, I18n.t("errors.app.der_export") if format == "der" && (include_key || include_chain)
    entries = records.map do |record|
      raise Certificates::Error, I18n.t("errors.app.read_permission") unless identity.reader?(record.area)
      material = CertificateMaterial.load(record, private_key: include_key, password: source_password)
      material = CertificateMaterial.with_chain(record, material, identity) if include_chain
      material[:chain] = [] unless include_chain
      material
    end
    result = encode(records, entries, format: format, password: password)
    AuditEvent.record_export!(records, entries, identity: identity, format: format,
      include_key: include_key, include_chain: include_chain, filename: result[1])
    result
  end

  def self.encode(records, entries, format:, password:)
    if format == "jks"
      return [Certificates::Jks.dump(entries, password: password), "zertifikate.jks", "application/octet-stream"]
    end
    contents = entries.map do |entry|
      cert, key, chain = entry.values_at(:certificate, :key, :chain)
      case format
      when "pem"
        cert.to_pem + chain.map(&:to_pem).join + (key ? key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), password) : "")
      when "der" then cert.to_der
      when "p12"
        Certificates::Pkcs12.dump([entry], password: password)
      end
    end
    return [contents.first, "zertifikat-#{records.first.fingerprint.first(12)}.#{format}", "application/octet-stream"] if records.size == 1
    zip = Zip::OutputStream.write_buffer do |stream|
      contents.each_with_index do |content, i|
        stream.put_next_entry("#{records[i].area}/#{records[i].id}-#{records[i].fingerprint.first(12)}.#{format}")
        stream.write(content)
      end
    end
    [zip.string, "zertifikate.zip", "application/zip"]
  end
end
