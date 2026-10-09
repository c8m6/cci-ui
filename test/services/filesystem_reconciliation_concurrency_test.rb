# frozen_string_literal: true

require "test_helper"

class FilesystemReconciliationConcurrencyTest < ActiveSupport::TestCase
  # Separate PostgreSQL sessions must see committed rows, not a test transaction.
  self.use_transactional_tests = false

  setup do
    @previous_configuration = AreaConfiguration.configuration
    @previous_settings = FilesystemReconciliationConfiguration.configuration
    @directory = Dir.mktmpdir("cci-reconciliation-concurrency-")
    configure_legacy_paths("zone_a" => @directory)
    cert, = issue
    5.times { |index| File.write(File.join(@directory, "cert-#{index}.pem"), cert.to_pem) }
    CatalogIndexer.new.filesystem
    @records = Certificate.where(source: "filesystem", filesystem_source_path: @directory).order(:id).to_a
    File.delete(File.join(@directory, "cert-0.pem"))
  end

  teardown do
    Certificate.where(id: @records.map(&:id)).delete_all
    AuditEvent.where(area: "zone_a", actor: "indexer").delete_all
    AreaConfiguration.instance_variable_set(:@configuration, @previous_configuration)
    FilesystemReconciliationConfiguration.instance_variable_set(:@configuration, @previous_settings)
    FileUtils.remove_entry(@directory)
  end

  test "overlapping indexers scan serially and delete only after two complete observations" do
    run = -> { CatalogIndexer.new.filesystem }
    overlapping_scans(run, run) do |phase|
      assert_equal phase - 1, @records.first.reload.filesystem_missing_scans
      assert Certificate.exists?(@records.first.id)
    end
    assert_not(Certificate.uncached { Certificate.exists?(@records.first.id) })
    assert_equal 1, AuditEvent.where(area: "zone_a", actor: "indexer", action: "delete").count
  end

  test "concurrent administrator approvals cannot reuse IDs or delete twice" do
    ids = confirm_mass_absence
    first = -> { FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "first-operator") }
    second = lambda do
      FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "second-operator")
    rescue ArgumentError => e
      e
    end
    results = overlapping_scans(first, second) do |phase|
      assert_equal(phase == 1 ? 3 : 0, Certificate.uncached { Certificate.where(id: ids).count })
    end
    assert_instance_of ArgumentError, results.last
    event = AuditEvent.find_by!(action: "delete", actor: "first-operator")
    assert_equal ids.tally, event.details.fetch("certificates").pluck("id").tally
    assert_empty AuditEvent.where(action: "delete", actor: "second-operator")
  ensure
    AuditEvent.where(actor: %w[first-operator second-operator]).delete_all
  end

  test "an administrator waits for a scheduled scan and only approved IDs bypass its block" do
    ids = confirm_mass_absence
    scheduled = -> { CatalogIndexer.new.filesystem }
    approved = -> { FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "operator") }
    overlapping_scans(scheduled, approved) do |_phase|
      assert_equal(3, Certificate.uncached { Certificate.where(id: ids).count })
      assert_empty AuditEvent.where(action: "delete")
    end
    assert_equal(0, Certificate.uncached { Certificate.where(id: ids).count })
    assert_equal ["operator"], AuditEvent.where(action: "delete").pluck(:actor)
  ensure
    AuditEvent.where(actor: "operator", action: "delete").delete_all
  end

  private

  def confirm_mass_absence
    [1, 2].each { |index| File.delete(File.join(@directory, "cert-#{index}.pem")) }
    2.times { CatalogIndexer.new.filesystem }
    @records.first(3).map(&:id)
  end

  def overlapping_scans(first_run, second_run)
    original = LegacyStore.method(:inventory)
    reached = Queue.new
    continue_scan = Queue.new
    scans = 0
    LegacyStore.define_singleton_method(:inventory) do |**args, &block|
      scans += 1
      reached << scans
      continue_scan.pop
      original.call(**args, &block)
    end
    threads = []
    threads << Thread.new(&first_run)
    assert_equal 1, Timeout.timeout(10) { reached.pop }
    threads << Thread.new(&second_run)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.uncached do
            connection.select_value("SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' " \
                                    "AND classid = 0 AND objid = 81420911 AND NOT granted").to_i
          end
        end
        break if waiting.positive?

        sleep 0.01
      end
    end
    assert_equal 1, scans
    yield 1
    continue_scan << true
    assert_equal 2, Timeout.timeout(10) { reached.pop }
    yield 2
    continue_scan << true
    Timeout.timeout(10) { threads.map(&:value) }
  ensure
    2.times { continue_scan << true } if continue_scan
    threads&.each { |thread| thread.join(10) || thread.kill }
    LegacyStore.define_singleton_method(:inventory, original) if original
  end
end
