# frozen_string_literal: true

module CertificateDiagnostics
  # Additional root-store policy shares baseline path construction and can choose
  # a different valid cross-signed path. CT data is only required by SCT rules.
  class ChromePolicy
    def initialize(material, config, profile: nil, ct_profile: nil)
      @material = material
      @config = config
      @profile = profile
      @ct_profile = ct_profile
    end

    def call
      @profile ||= Profiles.load("trust_chrome", @config)
      outcome = Trust.new(@material, @config, profile: @profile, policy: self).call("trust_chrome")
      outcome[:data_version] = Profiles.version("chrome_policy", @config)
      outcome[:expires_at] = [outcome[:expires_at], @ct_profile&.fetch("expires_at")].compact.min
      outcome[:details] = (outcome[:details] || {}).merge("scope" => "chrome_policy", "baseline" => @baseline || "unknown")
      outcome[:details]["ct_error"] = @ct_error if @ct_error
      if @ct_profile
        outcome[:details].merge!("ct_profile" => @ct_profile.fetch("release"), "ct_checked_at" => @ct_profile.fetch("source_checked_at"),
          "ct_version" => @ct_profile.fetch("version"))
      end
      outcome
    rescue Error => e
      { state: "unknown", reason: e.message }
    end

    def evaluate(path, root)
      @baseline = "good"
      anchor = root.fetch("chrome")
      raise KeyError unless anchor["sha256_hex"] == [Certificates::Codec.fingerprint(path.last)]

      scts = (evidence(path) if Array(anchor["constraints"]).any? { |set| set.keys.intersect?(%w[sct_not_after_sec sct_all_after_sec]) })
      ChromeConstraints.new(@material.certificate, target: @config.trust["trust_chrome"]["target"], scts: scts)
                       .call(anchor, schema_digest: @profile.fetch("schema_sha256"))
    rescue KeyError
      { state: "unknown", reason: "unsupported_policy" }
    end

    private

    def evidence(path)
      @ct_profile ||= Profiles.load("chrome_policy", @config)
      EmbeddedScts.new(path.first, path[1], @ct_profile.fetch("logs")) if path.size > 1
    rescue Error => e
      @ct_error = e.message
      nil
    end
  end
end
