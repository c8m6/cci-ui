# frozen_string_literal: true

require "test_helper"

class DiagnosticConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @workers = []
    @record = CatalogIndexer.new.upsert(issue(name: "Concurrent synthetic root", ca: true).first,
      area: "zone_a", source: "consul", source_id: "concurrency/1", tags: [], active: true)
    @job = CertificateDiagnosticResult.create!(area: @record.area, fingerprint: @record.fingerprint,
      check_id: "ocsp", next_due_at: 1.hour.ago)
  end

  teardown do
    @workers.each do |worker|
      Process.kill("KILL", worker[:pid]) unless worker[:waited]
      Process.wait(worker[:pid]) unless worker[:waited]
      worker.values_at(:commands, :events, :errors).each(&:close)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    CertificateDiagnosticResult.delete_all
    CertificateDiagnosticCache.delete_all
    Certificate.where(id: @record&.id).delete_all
  end

  def start_worker(state, mode = "enabled")
    commands_read, commands_write = IO.pipe
    events_read, events_write = IO.pipe
    errors = Tempfile.new("diagnostic-worker")
    pid = Process.spawn(RbConfig.ruby, "-r./config/environment", "test/support/diagnostic_worker.rb", state, mode,
      in: commands_read, out: File::NULL, err: errors, 3 => events_write)
    commands_read.close
    events_write.close
    worker = { pid: pid, commands: commands_write, events: events_read, errors: errors }
    @workers << worker
    worker
  end

  def event(worker)
    Timeout.timeout(15) { worker[:events].gets&.strip }
  end

  def finish(worker, publish: false)
    worker[:commands].puts("publish") if publish
    assert_equal "finished", event(worker), File.read(worker[:errors].path)
    _, status = Process.wait2(worker[:pid])
    worker[:waited] = true
    assert status.success?, File.read(worker[:errors].path)
  end

  test "parallel indexers claim once and expired owners cannot overwrite recovery results or scheduling" do
    old = start_worker("revoked")
    assert_equal "claimed:#{@job.id}", event(old)
    finish(start_worker("good"))
    finish(start_worker("good", "disabled"))
    assert_nil @job.reload.checked_at
    assert_not @job.suspended
    old_input = @job.input_version
    CertificateDiagnosticCache.where(cache_id: CertificateDiagnostics::Runner::LEASE).update_all(lease_until: 1.second.ago)
    recovered = start_worker("good")
    assert_equal "claimed:#{@job.id}", event(recovered)
    finish(recovered, publish: true)
    assert_equal "good", @job.reload.state
    checked_at = @job.checked_at
    next_due_at = @job.next_due_at
    # A changed input would be rescheduled by an unfenced late scheduler.
    @job.update!(input_version: "newer-owner-input")
    finish(old, publish: true)
    assert_equal "good", @job.reload.state
    assert_equal checked_at, @job.checked_at
    assert_equal next_due_at, @job.next_due_at
    assert_equal "newer-owner-input", @job.input_version
    assert_not_equal old_input, @job.input_version
    assert_nil @job.revoked_at
  end
end
