# frozen_string_literal: true

# A separate Rails process exercises the real scheduler and publication fences.
# The pipe barrier substitutes only the slow external check, using synthetic data.
class DiagnosticWorker < CertificateDiagnostics::Runner
  def evaluate(job)
    EVENTS.puts("claimed:#{job.id}")
    raise "Missing test barrier release" unless $stdin.gets == "publish\n"

    schedule # A resumed worker must not mutate scheduling after losing its lease.
    publish(job, { state: ARGV.fetch(0), reason: ARGV.fetch(0), expires_at: 1.hour.from_now }, nil)
  end
end

EVENTS = IO.new(3, "w")
EVENTS.sync = true
config = CertificateDiagnosticsConfiguration.new("CCI_OCSP_ENABLED" => (ARGV[1] != "disabled").to_s,
  "CCI_DIAGNOSTICS_PASS_BUDGET" => "60", "CCI_DIAGNOSTICS_BATCH_SIZE" => "1")
DiagnosticWorker.new(config).run
EVENTS.puts("finished")
