# frozen_string_literal: true

require "zip"
# Authorises every selected entry and audits the export before releasing bytes.
class CertificateExport
  FORMATS = %w[pem der p12 jks].freeze
  def self.call(records, identity:, format:, include_key:, include_chain:, password:, source_password: "")
    validate_export(records, identity: identity, format: format, include_key: include_key,
      include_chain: include_chain, password: password)

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
    return [Certificates::Jks.dump(entries, password: password), "certificates.jks", "application/octet-stream"] if format == "jks"

    contents = entries.map do |entry|
      cert, key, chain = entry.values_at(:certificate, :key, :chain)
      case format
      when "pem"
        encrypted_key = key ? key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), password) : ""
        cert.to_pem + chain.map(&:to_pem).join + encrypted_key
      when "der" then cert.to_der
      when "p12"
        Certificates::Pkcs12.dump([entry], password: password)
      end
    end
    if records.size == 1
      return [contents.first, "certificate-#{records.first.fingerprint.first(12)}.#{format}",
        "application/octet-stream"]
    end

    zip = Zip::OutputStream.write_buffer do |stream|
      contents.each_with_index do |content, i|
        stream.put_next_entry("#{records[i].area}/#{records[i].id}-#{records[i].fingerprint.first(12)}.#{format}")
        stream.write(content)
      end
    end
    [zip.string, "certificates.zip", "application/zip"]
  end

  # Check permissions and output constraints before loading private material.
  def self.validate_export(records, identity:, format:, include_key:, include_chain:, password:)
    raise Certificates::Error, I18n.t("errors.app.unknown_export") unless FORMATS.include?(format)
    raise Certificates::Error, I18n.t("errors.app.export_count") unless (1..100).cover?(records.size)
    raise Certificates::Error, I18n.t("errors.app.reader_export") if records.any? { |record| !identity.export?(record.area) }
    if include_key && records.any? { |record| !identity.export_key?(record.area) }
      raise Certificates::Error, I18n.t("errors.app.key_export_role")
    end

    validate_format(format, include_key, include_chain, password)
  end

  def self.validate_format(format, include_key, include_chain, password)
    password_required = include_key || %w[p12 jks].include?(format)
    raise Certificates::Error, I18n.t("errors.app.export_password") if password_required && password.length < 12
    raise Certificates::Error, I18n.t("errors.app.der_export") if format == "der" && (include_key || include_chain)
  end
end
