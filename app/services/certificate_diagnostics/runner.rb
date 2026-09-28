# frozen_string_literal: true

module CertificateDiagnostics
  # One expiring phase lease prevents duplicate downloads across indexers. No
  # transaction or catalogue advisory lock spans material loading or networking.
  class Runner
    LEASE = "diagnostic-phase"

    def self.run(config = CertificateDiagnosticsConfiguration.new)
      new(config).run
    rescue StandardError => e
      OperationalLog.warn(logger: "cci.diagnostics", message: "Diagnostic phase failed", error_code: e.class.name)
    end

    def initialize(config)
      @config = config
    end

    def run
      @token = CertificateDiagnosticCache.acquire(LEASE, seconds: @config[:pass_budget] + 10)
      return unless @token

      CertificateDiagnosticCache.with_lease(LEASE, @token) do
        CertificateDiagnosticResult.where.not(check_id: @config.enabled).update_all(suspended: true)
      end
      return if @config.enabled.empty?

      @deadline = monotonic + @config[:pass_budget]
      Timeout.timeout(@config[:pass_budget], Error, "deadline") do
        Profiles.new(@config, deadline: @deadline, token: @token).refresh
        schedule
        due.limit(@config[:batch_size]).each do |job|
          break if monotonic >= @deadline

          evaluate(job)
        end
      end
    ensure
      CertificateDiagnosticCache.release(LEASE, @token) if @token
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def due
      CertificateDiagnosticResult.where(suspended: false, check_id: @config.enabled)
                                 .where("next_due_at <= ?", Time.current).order(next_due_at: :asc, priority: :desc, id: :asc)
    end

    def schedule
      AreaConfiguration.ids.each do |area|
        versions = Inventory.new(area).versions
        @config.enabled.each { |check| schedule_check(area, check, versions) }
      end
      # Deleted source records are never evaluated, even if they had a due job.
      CertificateDiagnosticCache.with_lease(LEASE, @token) do
        CertificateDiagnosticResult.where(<<~SQL.squish).delete_all
          NOT EXISTS (SELECT 1 FROM certificates c WHERE c.deleted_at IS NULL
            AND c.area = certificate_diagnostic_results.area
            AND c.fingerprint = certificate_diagnostic_results.fingerprint)
        SQL
      end
    end

    def schedule_check(area, check, inventory)
      connection = CertificateDiagnosticResult.connection
      profile = @config.trust.profiles.key?(check) ? Profiles.version(check, @config) : ""
      configuration = @config.version(check) + profile
      inputs = inventory.transform_values { |version| Digest::SHA256.hexdigest(version + configuration) }
      values = [area, check, inputs.to_json, Time.current].map { |value| connection.quote(value) }
      sql = <<~SQL
        INSERT INTO certificate_diagnostic_results
          (area, fingerprint, check_id, input_version, next_due_at, priority, created_at, updated_at)
        SELECT area, fingerprint, #{values[1]}, inputs.value, #{values[3]},
          bool_or(active AND NOT archived), #{values[3]}, #{values[3]}
        FROM certificates JOIN jsonb_each_text(#{values[2]}::jsonb) inputs ON inputs.key = fingerprint
        WHERE area = #{values[0]} AND deleted_at IS NULL GROUP BY area, fingerprint, inputs.value
        ON CONFLICT (area, fingerprint, check_id) DO UPDATE SET
          priority = EXCLUDED.priority,
          next_due_at = CASE WHEN certificate_diagnostic_results.suspended OR
            certificate_diagnostic_results.input_version IS DISTINCT FROM EXCLUDED.input_version
            THEN LEAST(certificate_diagnostic_results.next_due_at, EXCLUDED.next_due_at)
            ELSE certificate_diagnostic_results.next_due_at END,
          expires_at = CASE WHEN certificate_diagnostic_results.suspended OR
            certificate_diagnostic_results.input_version IS DISTINCT FROM EXCLUDED.input_version
            THEN LEAST(certificate_diagnostic_results.expires_at, EXCLUDED.next_due_at)
            ELSE certificate_diagnostic_results.expires_at END,
          input_version = EXCLUDED.input_version, suspended = false
      SQL
      CertificateDiagnosticCache.with_lease(LEASE, @token) { connection.execute(sql) }
    end

    def evaluate(job)
      started = monotonic
      record = Certificate.retained.where(area: job.area, fingerprint: job.fingerprint).order(active: :desc, id: :asc).first
      return unless record

      material = Material.new(record)
      http = Http.new(@config, deadline: @deadline)
      outcome = if job.check_id == "chrome_policy"
                  ChromePolicy.new(material, @config).call
                elsif job.check_id.start_with?("trust_")
                  Trust.new(material, @config).call(job.check_id)
                else
                  Revocation.new(material, @config, http: http, area: job.area).call(job.check_id)
                end
      return unless material.current?

      publish(job, outcome, material.certificate)
      OperationalLog.info(logger: "cci.diagnostics", message: "Certificate diagnostic completed", check: job.check_id,
        certificate_id: record.id, area: job.area, result: outcome[:state], reason: outcome[:reason],
        duration_ms: ((monotonic - started) * 1000).round(1))
    rescue StandardError => e
      publish(job, { state: "unknown", reason: e.is_a?(Error) ? e.message : "material_unavailable" }, nil)
    end

    def publish(job, outcome, cert)
      now = Time.current
      conclusive = %w[good revoked untrusted].include?(outcome[:state])
      expiry = outcome[:expires_at]
      transition = cert && [cert.not_before, cert.not_after].select { |time| time > now }.min
      expiry = [expiry, transition].compact.min
      delay = conclusive ? @config.interval(job.check_id) : [300 * (2**[job.failures, 5].min), @config.interval(job.check_id)].min
      attrs = { last_attempt_at: now, next_due_at: [now + delay, expiry].compact.select { |time| time > now }.min,
                last_error: conclusive ? nil : outcome[:reason], failures: conclusive ? 0 : job.failures + 1 }
      if conclusive || !%w[good revoked untrusted].include?(job.state)
        attrs.merge!(outcome.slice(:state, :reason, :data_version, :details)).merge!(checked_at: now, expires_at: expiry)
        attrs[:details] = (attrs[:details] || {}).merge("configuration" => @config.version(job.check_id))
      end
      attrs[:revoked_at] = now if outcome[:state] == "revoked" && !job.revoked_at
      persist(job, attrs)
    end

    def persist(job, attrs)
      # Fence late workers after crash recovery. This short transaction contains
      # only database operations, and serializes against lease acquisition.
      CertificateDiagnosticCache.with_lease(LEASE, @token) do
        return unless Certificate.retained.exists?(area: job.area, fingerprint: job.fingerprint)

        job.update!(attrs)
      end
    end
  end
end
