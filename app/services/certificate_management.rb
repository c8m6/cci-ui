# frozen_string_literal: true

# Optional external-writer metadata, read from Consul rather than the catalog.
class CertificateManagement
  def self.automated?(metadata)
    metadata.is_a?(Hash) && metadata.key?("acme_renewal")
  end

  def self.renewal_summary(metadata)
    return unless automated?(metadata)

    summary = metadata["acme_renewal"]
    return unless summary.is_a?(Hash) && valid_summary?(summary)

    summary.slice("domains", "key_type", "key_size", "version").merge("not_after" => Time.iso8601(summary.fetch("not_after")))
  rescue ArgumentError
    nil
  end

  def self.valid_summary?(summary)
    domains = summary["domains"]
    summary["not_after"].is_a?(String) && domains.is_a?(Array) && domains.any? &&
      domains.all? { |domain| domain.is_a?(String) && domain.present? } &&
      %w[rsa ec].include?(summary["key_type"]) && positive_integer?(summary["key_size"]) &&
      (!summary.key?("version") || positive_integer?(summary["version"]))
  end

  def self.positive_integer?(value)
    value.is_a?(Integer) && value.positive?
  end
end
