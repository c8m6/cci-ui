# frozen_string_literal: true

module CertificateDiagnostics
  # Three-valued evaluation: AND within each set, OR across alternative sets.
  class ChromeConstraints
    SCHEMA_DIGEST = "79fc7fd7fa70b6337405e0fb7639e1621f66618b144930cf59ce630538b105be"
    ANCHOR_FIELDS = %w[sha256_hex ev_policy_oids constraints display_name eutl enforce_anchor_expiry
      enforce_anchor_constraints tls_trust_anchor trust_anchor_id crs_root_id].freeze
    FIELDS = %w[sct_not_after_sec sct_all_after_sec min_version max_version_exclusive permitted_dns_names
      index_not_after index_after validity_starts_not_after_sec validity_starts_after_sec].freeze

    def initialize(certificate, target:, scts: nil)
      @certificate = certificate
      @target = target
      @scts = scts
    end

    def call(anchor, schema_digest:)
      return unknown("unsupported_schema") unless schema_digest == SCHEMA_DIGEST && (anchor.keys - ANCHOR_FIELDS).empty?
      return unknown("unsupported_policy") unless anchor_flags_valid?(anchor)
      return unknown("not_applicable") if TrustPaths.ca?(@certificate)

      alternatives = Array(anchor["constraints"])
      outcomes = alternatives.map { |set| evaluate_set(set) }
      return { state: "good", reason: "chrome_policy_satisfied" } if alternatives.empty? || outcomes.include?(true)
      return unknown("chrome_policy_incomplete") if outcomes.include?(nil)

      { state: "untrusted", reason: "chrome_policy_rejected" }
    rescue ArgumentError, TypeError, OpenSSL::OpenSSLError
      unknown("unsupported_policy")
    end

    private

    def unknown(reason) = { state: "unknown", reason: reason }

    def anchor_flags_valid?(anchor)
      %w[enforce_anchor_expiry enforce_anchor_constraints tls_trust_anchor].all? do |field|
        !anchor.key?(field) || [[true], [false]].include?(anchor[field])
      end
    end

    def evaluate_set(set)
      return unless set.is_a?(Hash) && (set.keys - FIELDS).empty?

      outcomes = set.map do |field, values|
        next evaluate_dns(values) if field == "permitted_dns_names"
        next unless values.is_a?(Array) && values.size == 1

        evaluate_field(field, values.first)
      end
      return false if outcomes.include?(false)
      return if outcomes.include?(nil)

      true
    end

    def evaluate_field(field, value)
      case field
      when "min_version" then compare_version(value) { |comparison| comparison >= 0 }
      when "max_version_exclusive" then compare_version(value, &:negative?)
      when "index_after", "index_not_after" then value.is_a?(Integer) || nil # Classical X.509 ignores MTC index rules.
      when "validity_starts_after_sec" then value.is_a?(Integer) ? @certificate.not_before.to_i > value : nil
      when "validity_starts_not_after_sec" then value.is_a?(Integer) ? @certificate.not_before.to_i <= value : nil
      when "sct_not_after_sec", "sct_all_after_sec" then evaluate_sct(field, value)
      end
    end

    def compare_version(value)
      return unless value.is_a?(String) && value.match?(/\A\d+(?:\.\d+)*\z/)

      yield Gem::Version.new(@target) <=> Gem::Version.new(value)
    end

    def evaluate_sct(field, value)
      return unless value.is_a?(Integer) && @scts&.timestamps&.any?

      earlier = @scts.timestamps.any? { |timestamp| timestamp <= value * 1000 }
      return earlier ? true : nil if field == "sct_not_after_sec"
      return false if earlier
      return if @scts.unverified

      true
    end

    def evaluate_dns(constraints)
      return unless constraints.is_a?(Array) && constraints.all? { |name| domain?(name.to_s.delete_prefix(".")) }

      names = dns_names
      return unless names.all? { |name| domain?(name.delete_prefix("*.")) }

      names.all? do |name|
        constraints.any? { |subtree| within_subtree?(name, subtree) }
      end
    end

    def dns_names
      extension = @certificate.extensions.find { |entry| entry.oid == "subjectAltName" }
      return [] unless extension

      value = OpenSSL::ASN1.decode(extension.to_der).value.last.value
      OpenSSL::ASN1.decode(value).value.select { |name| name.tag_class == :CONTEXT_SPECIFIC && name.tag == 2 }.map(&:value)
    end

    def within_subtree?(name, subtree)
      name = name.downcase.delete_suffix(".")
      subtree = subtree.downcase.delete_suffix(".")
      name == subtree || name.end_with?(subtree.start_with?(".") ? subtree : ".#{subtree}")
    end

    def domain?(name)
      name.is_a?(String) && name.ascii_only? && name.length.between?(1, 254) &&
        name.delete_suffix(".").split(".", -1).all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i) }
    end
  end
end
