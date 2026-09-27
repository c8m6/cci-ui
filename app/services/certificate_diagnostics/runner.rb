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
      CertificateDiagnosticResult.where.not(check_id: @config.enabled).update_all(suspended: true)
      return if @config.enabled.empty?

      @token = CertificateDiagnosticCache.acquire(LEASE, seconds: @config[:pass_budget] + 10)
      return unless @token

      @deadline = monotonic + @config[:pass_budget]
      Timeout.timeout(@config[:pass_budget], Error, "deadline") do
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
        version = Material.inventory_version(area)
        @config.enabled.each { |check| schedule_check(area, check, version) }
      end
      # Deleted source records are never evaluated, even if they had a due job.
      CertificateDiagnosticResult.where(<<~SQL.squish).delete_all
        NOT EXISTS (SELECT 1 FROM certificates c WHERE c.deleted_at IS NULL
          AND c.area = certificate_diagnostic_results.area
          AND c.fingerprint = certificate_diagnostic_results.fingerprint)
      SQL
    end

    def schedule_check(area, check, inventory)
      connection = CertificateDiagnosticResult.connection
      input = Digest::SHA256.hexdigest(inventory + @config.version(check))
      values = [area, check, input].map { |value| connection.quote(value) }
      connection.execute(<<~SQL)
        INSERT INTO certificate_diagnostic_results
          (area, fingerprint, check_id, input_version, next_due_at, priority, created_at, updated_at)
        SELECT area, fingerprint, #{values[1]}, #{values[2]}, CURRENT_TIMESTAMP,
          bool_or(active AND NOT archived), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM certificates WHERE area = #{values[0]} AND deleted_at IS NULL GROUP BY area, fingerprint
        ON CONFLICT (area, fingerprint, check_id) DO UPDATE SET
          priority = EXCLUDED.priority,
          next_due_at = CASE WHEN certificate_diagnostic_results.suspended OR
            certificate_diagnostic_results.input_version IS DISTINCT FROM EXCLUDED.input_version
            THEN CURRENT_TIMESTAMP ELSE certificate_diagnostic_results.next_due_at END,
          expires_at = CASE WHEN certificate_diagnostic_results.suspended OR
            certificate_diagnostic_results.input_version IS DISTINCT FROM EXCLUDED.input_version
            THEN CURRENT_TIMESTAMP ELSE certificate_diagnostic_results.expires_at END,
          input_version = EXCLUDED.input_version, suspended = false
      SQL
    end

    def evaluate(job)
      started = monotonic
      record = Certificate.retained.where(area: job.area, fingerprint: job.fingerprint).order(active: :desc, id: :asc).first
      return unless record

      material = Material.new(record)
      http = Http.new(@config, deadline: @deadline)
      outcome = Revocation.new(material, @config, http: http, area: job.area).call(job.check_id)
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
      conclusive = %w[good revoked].include?(outcome[:state])
      expiry = outcome[:expires_at]
      transition = cert && [cert.not_before, cert.not_after].select { |time| time > now }.min
      expiry = [expiry, transition].compact.min
      delay = conclusive ? @config.interval(job.check_id) : [300 * (2**[job.failures, 5].min), @config.interval(job.check_id)].min
      attrs = { last_attempt_at: now, next_due_at: [now + delay, expiry].compact.select { |time| time > now }.min,
                last_error: conclusive ? nil : outcome[:reason], failures: conclusive ? 0 : job.failures + 1 }
      if conclusive || !%w[good revoked].include?(job.state)
        attrs.merge!(outcome.slice(:state, :reason, :data_version, :details)).merge!(checked_at: now, expires_at: expiry)
      end
      attrs[:revoked_at] = now if outcome[:state] == "revoked" && !job.revoked_at
      persist(job, attrs, now)
    end

    def persist(job, attrs, now)
      # Fence late workers after crash recovery. This short transaction contains
      # only database operations, and serializes against lease acquisition.
      CertificateDiagnosticCache.transaction do
        lease = CertificateDiagnosticCache.lock.find_by(cache_id: LEASE, lease_token: @token)
        return unless lease && lease.lease_until > now
        return unless Certificate.retained.exists?(area: job.area, fingerprint: job.fingerprint)

        job.update!(attrs)
      end
    end
  end
end
