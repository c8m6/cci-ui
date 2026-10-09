# frozen_string_literal: true

require "test_helper"

class FilesystemReconciliationConcurrencyTest < ActiveSupport::TestCase
  # Separate PostgreSQL sessions must see committed rows, not a test transaction.
  self.use_transactional_tests = false

  setup do
    @previous_configuration = AreaConfiguration.configuration
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
    FileUtils.remove_entry(@directory)
  end

  test "overlapping indexers scan serially and delete only after two complete observations" do
    original = LegacyStore.method(:inventory)
    reached = Queue.new
    continue_scan = Queue.new
    scans = 0
    LegacyStore.define_singleton_method(:inventory) do |**args|
      scans += 1
      reached << scans
      continue_scan.pop
      original.call(**args)
    end
    threads = []
    threads << Thread.new { CatalogIndexer.new.filesystem }
    assert_equal 1, Timeout.timeout(10) { reached.pop }
    threads << Thread.new { CatalogIndexer.new.filesystem }
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.uncached do
            connection.select_value("SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted").to_i
          end
        end
        break if waiting.positive?

        sleep 0.01
      end
    end
    assert_equal 1, scans
    assert_equal 0, @records.first.reload.filesystem_missing_scans
    continue_scan << true
    assert_equal 2, Timeout.timeout(10) { reached.pop }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
    assert Certificate.exists?(@records.first.id)
    continue_scan << true
    Timeout.timeout(10) { threads.each(&:value) }
    assert_not(Certificate.uncached { Certificate.exists?(@records.first.id) })
    assert_equal 1, AuditEvent.where(area: "zone_a", actor: "indexer", action: "delete").count
  ensure
    2.times { continue_scan << true } if continue_scan
    threads&.each { |thread| thread.join(10) || thread.kill }
    LegacyStore.define_singleton_method(:inventory, original) if original
  end
end
