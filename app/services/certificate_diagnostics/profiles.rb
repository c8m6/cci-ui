# frozen_string_literal: true

module CertificateDiagnostics
  # Durable, atomic public datasets. Last valid contents survive failed refreshes.
  class Profiles
    def self.record(check) = CertificateDiagnosticCache.find_by(cache_id: "profile:#{check}")

    def self.version(check, config)
      row = record(check)
      matches = row&.metadata&.fetch("target", nil) == config.trust[check]["target"]
      version = matches ? row.metadata.fetch("version", "unavailable") : "unavailable"
      check == "chrome_policy" ? Digest::SHA256.hexdigest(version + self.version("trust_chrome", config)) : version
    end

    def self.load(check, config)
      row = record(check)
      raise Error, "source_unavailable" unless row&.payload && row.metadata["target"] == config.trust[check]["target"]

      expiry = row.source_expires_at(max_age: config.trust[check]["max_age"], timestamp: "checked_at")
      raise Error, "source_expired" unless expiry && expiry > Time.current

      JSON.parse(row.payload).merge("version" => row.metadata.fetch("version"), "expires_at" => expiry,
        "source_checked_at" => row.metadata.fetch("checked_at"), "source_error" => row.metadata["last_error"])
    end

    def self.evidence_expired?(check, details, config, now)
      return false unless config.trust.profiles.key?(check)

      sources = { "source_checked_at" => check == "chrome_policy" ? "trust_chrome" : check }
      sources["ct_checked_at"] = "chrome_policy" if check == "chrome_policy"
      sources.any? do |field, profile|
        details[field] && Time.iso8601(details[field]) + config.trust[profile]["max_age"] <= now
      end
    rescue ArgumentError, TypeError
      true
    end

    def initialize(config, deadline:, token:)
      @config = config
      @deadline = deadline
      @token = token
    end

    def refresh
      checks = @config.enabled & TrustProfileConfiguration::DEFAULTS.keys
      due = checks.filter_map do |check|
        settings = @config.trust[check]
        row = self.class.record(check)
        meta = row&.metadata || {}
        time = meta["next_due_at"] && Time.iso8601(meta["next_due_at"])
        [check, time || Time.at(0)] if !time || time <= Time.current || meta.fetch("attempted_settings", meta["settings"]) != settings
      end.min_by(&:last)
      update(due.first) if due
    end

    private

    def update(check)
      settings = @config.trust[check]
      now = Time.current
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      data = acquire(check, settings)
      validate(data) unless check == "chrome_policy"
      source_time = Time.iso8601(data.fetch("acquired_at"))
      source_time = [source_time, Time.iso8601(data.fetch("timestamp"))].min if check == "chrome_policy"
      payload = JSON.generate(data.except("acquired_at"))
      meta = { "target" => settings["target"], "settings" => settings, "version" => Digest::SHA256.hexdigest(payload),
               "checked_at" => source_time.iso8601, "last_attempt_at" => now.iso8601,
               "next_due_at" => (now + settings["update_interval"]).iso8601 }
      save(check, payload: payload, expires_at: source_time + settings["max_age"], metadata: meta)
      OperationalLog.info(logger: "cci.diagnostics", message: "Public trust profile updated", check: check,
        roots: data.fetch("roots", {}).size, data_version: meta["version"],
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1))
    rescue StandardError => e
      failed(check, settings, e)
    end

    def acquire(check, settings)
      download = Sources::Download.new(@config, deadline: @deadline)
      options = { target: settings["target"], max_age: [settings["update_interval"], settings["max_age"]].min }
      data = case check
             when "chrome_policy" then Sources::CtLogs.new(download, **options, freshness: settings["max_age"]).call
             when "trust_chrome" then Sources::Chrome.new(download, **options).call
             when "trust_firefox" then Sources::Mozilla.new(download, **options).call
             when "trust_edge" then Sources::Ccadb.new(download, **options).call
             when "trust_apple", "trust_ubuntu"
               adapter = check == "trust_apple" ? Sources::Apple : Sources::Ubuntu
               adapter.new(download, **options, archive: Sources::Archive.new(@config.trust.limits.fetch("expanded_max_bytes"))).call
             end
      data.merge("acquired_at" => download.verified_at.iso8601)
    end

    def validate(data)
      roots = data.fetch("roots")
      raise Error, "source_verification_failed" unless roots.size.between?(1, 1000)

      roots.each do |fingerprint, root|
        cert = OpenSSL::X509::Certificate.new(root.fetch("pem"))
        raise Error, "source_verification_failed" unless fingerprint == Certificates::Codec.fingerprint(cert)
      end
    end

    def failed(check, settings, error)
      row = self.class.record(check)
      meta = (row&.metadata || {}).dup
      failures = meta.fetch("failures", 0) + 1
      delay = [300 * (2**[failures - 1, 5].min), settings["update_interval"]].min
      reason = error.is_a?(Error) ? error.message : "source_verification_failed"
      meta.merge!("attempted_settings" => settings, "last_attempt_at" => Time.current.iso8601,
        "last_error" => reason, "failures" => failures, "next_due_at" => (Time.current + delay).iso8601)
      save(check, metadata: meta)
      OperationalLog.warn(logger: "cci.diagnostics", message: "Public trust profile refresh failed", check: check, reason: reason)
    end

    def save(check, **attrs)
      CertificateDiagnosticCache.with_lease(Runner::LEASE, @token) do
        CertificateDiagnosticCache.find_or_initialize_by(cache_id: "profile:#{check}").update!(attrs)
      end
    end
  end
end
