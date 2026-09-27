# frozen_string_literal: true

module CertificateDiagnostics
  # Certificate-level CA/path trust, never a website or hostname probe.
  class Trust
    def initialize(material, config, profile: nil, policy: nil)
      @material = material
      @config = config
      @profile = profile
      @policy = policy
    end

    def call(check)
      profile = @profile || Profiles.load(check, @config)
      roots = profile.fetch("roots")
      paths = TrustPaths.new(@material.certificate, @material.candidates,
        roots.values.map { |entry| OpenSSL::X509::Certificate.new(entry.fetch("pem")) }, anchor_rules: roots)
      outcomes = paths.paths.map { |path| evaluate_path(path, roots) }
      selected = select_outcome(outcomes, paths)
      result(profile, selected)
    rescue Error => e
      { state: "unknown", reason: e.message }
    end

    private

    def select_outcome(outcomes, paths)
      selected = outcomes.find { |outcome| outcome[:state] == "good" }
      selected ||= { state: "unknown", reason: "missing_intermediate" } if paths.incomplete
      selected ||= outcomes.find { |outcome| outcome[:state] == "unknown" }
      selected || outcomes.first || { state: "untrusted", reason: paths.errors.include?("invalid_path") ? "invalid_path" : "private_root" }
    end

    def evaluate_path(path, roots)
      root = roots.fetch(Certificates::Codec.fingerprint(path.last))
      reason = restriction(root)
      return { state: "unknown", reason: reason } if reason == "unsupported_policy"
      return { state: "untrusted", reason: reason } if reason

      policy = @policy&.evaluate(path, root)
      evidence = { path: path.map { |cert| Certificates::Codec.fingerprint(cert) } }
      return policy.merge(evidence) if policy && policy[:state] != "good"

      reason = TrustPaths.ca?(@material.certificate) ? "ca_path_trusted" : "tls_path_trusted"
      { state: "good", reason: @policy ? "chrome_policy_satisfied" : reason,
        path: path.map { |cert| Certificates::Codec.fingerprint(cert) },
        path_expiry: path_expiry(path, root) }
    end

    def path_expiry(path, root)
      dates = path.flat_map { |cert| [cert.not_before, cert.not_after] }
      dates << Time.iso8601(root["disabled_at"]) if root["disabled_at"]
      # Issuance cutoffs such as distrust_after compare the leaf's fixed
      # notBefore, so passing that wall-clock date does not change its trust.
      dates.select { |date| date > Time.current }.min
    end

    def restriction(root)
      return "unsupported_policy" if root["unsupported_policy"]
      return "vendor_distrust" if root["denied"]
      return "vendor_distrust" if root["disabled_at"] && Time.current >= Time.iso8601(root["disabled_at"])
      return unless root["distrust_after"] && @material.certificate.not_before >= Time.iso8601(root["distrust_after"])

      "vendor_distrust"
    end

    def result(profile, selected)
      details = { "profile" => profile.fetch("release"), "source" => profile.fetch("source"), "scope" => profile.fetch("scope"),
                  "source_checked_at" => profile.fetch("source_checked_at"), "source_error" => profile["source_error"],
                  "path" => selected[:path], "root" => selected[:path]&.last }.compact
      { state: selected.fetch(:state), reason: selected.fetch(:reason), data_version: profile.fetch("version"),
        expires_at: [profile.fetch("expires_at"), selected[:path_expiry]].compact.min, details: details }
    end
  end
end
