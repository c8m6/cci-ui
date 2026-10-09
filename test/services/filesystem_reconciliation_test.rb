# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class FilesystemReconciliationTest < ActiveSupport::TestCase
  include CsrFixtures

  setup do
    @previous_configuration = AreaConfiguration.configuration
    @previous_settings = FilesystemReconciliationConfiguration.configuration
    @directory = Dir.mktmpdir("cci-reconciliation-")
    configure_legacy_paths("zone_a" => @directory)
    @cert, = issue
    10.times { |index| File.write(File.join(@directory, "cert-#{index}.pem"), @cert.to_pem) }
    scan
    @records = Certificate.where(source: "filesystem", area: "zone_a").order(:id).to_a
  end

  teardown do
    AreaConfiguration.instance_variable_set(:@configuration, @previous_configuration)
    FilesystemReconciliationConfiguration.instance_variable_set(:@configuration, @previous_settings)
    FileUtils.remove_entry(@directory)
  end

  def scan = CatalogIndexer.new.filesystem

  def remove_files(records = @records.first(1))
    records.each { |record| File.delete(File.join(@directory, record.source_id.rpartition("#").first)) }
  end

  def with_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name) { |*args, **options, &block| replacement.call(*args, **options, &block) }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  test "present certificates retain their identity and reset all missing state" do
    record = @records.first
    record.update!(filesystem_missing_scans: 1, filesystem_cleanup_blocked: true)
    scan
    assert_equal 0, record.reload.filesystem_missing_scans
    assert_not record.filesystem_cleanup_blocked
    assert_equal 10, Certificate.where(source: "filesystem").count
  end

  test "first absence marks missing and second complete scan removes only that row" do
    record = @records.first
    remove_files
    scan
    assert_equal 1, record.reload.filesystem_missing_scans
    assert Certificate.exists?(record.id)
    scan
    assert_not Certificate.exists?(record.id)
    assert_equal 9, Certificate.where(source: "filesystem").count
    event = AuditEvent.find_by!(action: "delete")
    assert_equal "indexer", event.actor
    assert_equal "succeeded", event.details.fetch("outcome")
    assert_equal 10, event.details.fetch("previous_count")
    assert_equal([record.id], event.details.fetch("certificates").map { |certificate| certificate.fetch("id") })
  end

  test "rediscovery resets confirmation so a later absence starts again" do
    record = @records.first
    remove_files
    scan
    File.write(File.join(@directory, record.source_id.rpartition("#").first), @cert.to_pem)
    scan
    assert_equal 0, record.reload.filesystem_missing_scans
    remove_files
    scan
    assert_equal 1, record.reload.filesystem_missing_scans
    assert Certificate.exists?(record.id)
  end

  test "unavailable storage never changes missing state or existing projections" do
    remove_files
    scan
    before = Certificate.order(:id).map(&:attributes)
    configure_legacy_paths("zone_a" => File.join(@directory, "offline"))
    3.times { assert_raises(Certificates::Error) { scan } }
    assert_equal before, Certificate.order(:id).map(&:attributes)
    assert_equal 1, @records.first.reload.filesystem_missing_scans
    configure_legacy_paths("zone_a" => @directory)
    scan
    assert_not Certificate.exists?(@records.first.id)
  end

  test "partial traversal and timeouts cannot reset or advance missing confirmations" do
    @records.last.update!(filesystem_missing_scans: 1)
    remove_files
    before = Certificate.order(:id).map(&:attributes)
    original = LegacyStore.method(:inventory)
    [Errno::EIO, Errno::EACCES, Timeout::Error, IOError].each do |error_type|
      failure = lambda do |**args|
        original.call(**args)
        raise error_type, "synthetic incomplete scan"
      end
      with_method(LegacyStore, :inventory, failure) { assert_raises(Certificates::Error) { scan } }
      assert_equal before, Certificate.order(:id).map(&:attributes)
    end
  end

  test "temporary loss of the configured directory preserves state and restoration rediscovers every row" do
    @records.last.update!(filesystem_missing_scans: 1)
    before = Certificate.order(:id).map(&:attributes)
    offline = "#{@directory}-offline"
    File.rename(@directory, offline)
    3.times { assert_raises(Certificates::Error) { scan } }
    assert_equal before, Certificate.order(:id).map(&:attributes)
    File.rename(offline, @directory)
    scan
    assert_equal @records.map(&:id), Certificate.where(source: "filesystem").order(:id).pluck(:id)
    assert_equal [0], Certificate.where(source: "filesystem").distinct.pluck(:filesystem_missing_scans)
    assert_empty AuditEvent.where(action: "delete")
  ensure
    File.rename(offline, @directory) if offline && File.exist?(offline)
  end

  test "disappearing files and unreadable companion metadata abort the complete source" do
    remove_files
    scan
    original = LegacyStore.method(:inventory)
    disappearing = lambda do |**args, &block|
      entries = original.call(**args)
      File.delete(File.join(@directory, entries.first.fetch(:relative)))
      block.call(entries)
      entries
    end
    with_method(LegacyStore, :inventory, disappearing) { assert_raises(Certificates::Error) { scan } }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
    assert_equal 10, Certificate.where(source: "filesystem").count
    File.write(File.join(@directory, "cert-1.pem"), @cert.to_pem)
    File.write(File.join(@directory, "cert-1.tag"), "synthetic tag")
    original_read = LegacyStore.method(:read)
    unreadable = lambda do |path|
      raise Errno::EACCES if path.extname == ".tag"

      original_read.call(path)
    end
    with_method(LegacyStore, :read, unreadable) { assert_raises(Certificates::Error) { scan } }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
  end

  test "changing or empty PEM files fail closed instead of confirming absence" do
    remove_files
    scan
    path = File.join(@directory, "cert-1.pem")
    original = LegacyStore.method(:inventory)
    changed = lambda do |**args, &block|
      entries = original.call(**args)
      File.write(path, @cert.to_pem + @cert.to_pem)
      block.call(entries)
      entries
    end
    with_method(LegacyStore, :inventory, changed) { assert_raises(Certificates::Error) { scan } }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
    File.write(path, "")
    assert_raises(Certificates::Error) { scan }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
  end

  test "empty readable storage repeatedly blocks all deletion" do
    remove_files(@records)
    5.times { scan }
    assert_equal 10, Certificate.where(source: "filesystem").count
    assert_equal [2], Certificate.where(source: "filesystem").distinct.pluck(:filesystem_missing_scans)
    assert_empty AuditEvent.where(action: "delete")
    @records.each { |record| File.write(File.join(@directory, record.source_id.rpartition("#").first), @cert.to_pem) }
    scan
    assert_equal [0], Certificate.where(source: "filesystem").distinct.pluck(:filesystem_missing_scans)
    assert_equal [false], Certificate.where(source: "filesystem").distinct.pluck(:filesystem_cleanup_blocked)
    assert_equal @records.map(&:id), Certificate.where(source: "filesystem").order(:id).pluck(:id)
  end

  test "rediscovery during companion reads aborts approval without deleting restored certificates" do
    remove_files(@records.first(3))
    2.times { scan }
    File.write(File.join(@directory, "cert-3.tag"), "synthetic tag")
    before = Certificate.order(:id).map(&:attributes)
    original = LegacyStore.method(:read)
    restore = lambda do |path|
      File.write(File.join(@directory, "cert-0.pem"), @cert.to_pem) if path.extname == ".tag"
      original.call(path)
    end
    with_method(LegacyStore, :read, restore) do
      assert_raises(Certificates::Error) do
        FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: @records.first(3).map(&:id), actor: "operator")
      end
    end
    assert_equal before, Certificate.order(:id).map(&:attributes)
    assert_empty AuditEvent.where(action: "delete")
    scan
    assert_equal 0, @records.first.reload.filesystem_missing_scans
    assert_not @records.first.filesystem_cleanup_blocked
  end

  test "partial subtree traversal failure preserves all rows and recovery resets missing state" do
    subtree = File.join(@directory, "subtree")
    Dir.mkdir(subtree)
    File.write(File.join(subtree, "nested.pem"), @cert.to_pem)
    scan
    nested = Certificate.find_by!(source_id: "subtree/nested.pem#0")
    remove_files
    scan
    before = Certificate.order(:id).map(&:attributes)
    original = Pathname.instance_method(:children)
    Pathname.define_method(:children) do |*args|
      raise Errno::EACCES, "synthetic subtree permission failure" if to_s == subtree

      original.bind_call(self, *args)
    end
    assert_raises(Certificates::Error) { scan }
    assert_equal before, Certificate.order(:id).map(&:attributes)
    assert_equal 0, nested.reload.filesystem_missing_scans
    Pathname.define_method(:children, original)
    File.write(File.join(@directory, "cert-0.pem"), @cert.to_pem)
    scan
    assert_equal 0, @records.first.reload.filesystem_missing_scans
    assert_equal 11, Certificate.where(source: "filesystem").count
  ensure
    Pathname.define_method(:children, original) if original
  end

  test "later companion reads cannot conceal changes to an already read certificate" do
    remove_files
    scan
    File.write(File.join(@directory, "cert-3.tag"), "synthetic tag")
    before = Certificate.order(:id).map(&:attributes)
    original = LegacyStore.method(:read)
    change = lambda do |path|
      File.write(File.join(@directory, "cert-1.pem"), @cert.to_pem + @cert.to_pem) if path.extname == ".tag"
      original.call(path)
    end
    with_method(LegacyStore, :read, change) { assert_raises(Certificates::Error) { scan } }
    assert_equal before, Certificate.order(:id).map(&:attributes)
    assert_empty AuditEvent.where(action: "delete")
  end

  test "a removed source preserves and logs its rows until explicitly configured again" do
    before = Certificate.order(:id).map(&:attributes)
    configure_legacy_paths({})
    events = []
    capture = ->(**fields) { events << fields }
    with_method(OperationalLog, :warn, capture) { 3.times { scan } }
    assert_equal before, Certificate.order(:id).map(&:attributes)
    assert(events.any? do |event|
      event[:operation] == "reconcile_filesystem" && event[:area] == "zone_a" && event[:retained_count] == 10
    end)
    configure_legacy_paths("zone_a" => @directory)
    scan
    assert_equal @records.map(&:id), Certificate.where(source: "filesystem").order(:id).pluck(:id)
    assert_empty AuditEvent.where(action: "delete")
  end

  test "identical certificates and relative names in different sources reconcile independently" do
    Dir.mktmpdir("cci-identical-source-") do |directory|
      10.times { |index| File.write(File.join(directory, "cert-#{index}.pem"), @cert.to_pem) }
      configure_legacy_paths("zone_a" => @directory, "zone_b" => directory)
      scan
      other = Certificate.where(area: "zone_b", source: "filesystem").order(:id).map(&:attributes)
      remove_files
      2.times { scan }
      assert_not Certificate.exists?(@records.first.id)
      remaining = Certificate.where(area: "zone_b", source: "filesystem").order(:id).map do |record|
        record.attributes.except("indexed_at", "updated_at")
      end
      assert_equal other.map { |row| row.except("indexed_at", "updated_at") }, remaining
      assert_empty AuditEvent.where(area: "zone_b", action: "delete")
    end
  end

  test "exactly twenty percent is allowed and more than twenty percent is all or nothing" do
    remove_files(@records.first(2))
    2.times { scan }
    assert_equal 8, Certificate.where(source: "filesystem").count
    remove_files(@records[2, 2])
    4.times { scan }
    assert_equal 8, Certificate.where(source: "filesystem").count
    assert(@records[2, 2].all? { |record| Certificate.exists?(record.id) })
  end

  test "new discoveries cannot dilute the previous database denominator" do
    remove_files(@records.first(3))
    scan
    20.times { |index| File.write(File.join(@directory, "new-#{index}.pem"), @cert.to_pem) }
    scan
    assert(@records.first(3).all? { |record| Certificate.exists?(record.id) })
    3.times { scan }
    assert(@records.first(3).all? { |record| Certificate.exists?(record.id) && record.reload.filesystem_cleanup_blocked })
    event_count = AuditEvent.where(action: "delete").count
    assert_equal 0, event_count
  end

  test "Consul rows CSRs and deletion tombstones remain independent" do
    consul = store(@cert)
    request = create_csr
    issued = upload_csr(request)
    record = @records.last
    record.update!(deleted_at: Time.current, active: false)
    original_consul = consul.attributes
    original_request = request.attributes
    original_issued = issued.attributes
    remove_files
    2.times { scan }
    assert_equal original_consul, consul.reload.attributes
    assert_equal original_request, request.reload.attributes
    assert_equal original_issued, issued.reload.attributes
    assert record.reload.deleted_at
    assert_not record.active
    assert_equal 0, record.filesystem_missing_scans
  end

  test "unknown source association and another root are never deletion candidates" do
    unassigned = @records[0]
    unassigned.update!(filesystem_source_path: nil)
    other = @records[1]
    other.update!(filesystem_source_path: File.join(@directory, "another-root"))
    remove_files([unassigned, other])
    3.times { scan }
    assert_equal 0, unassigned.reload.filesystem_missing_scans
    assert_equal 0, other.reload.filesystem_missing_scans
    assert Certificate.exists?(unassigned.id)
    assert Certificate.exists?(other.id)
  end

  test "configured source changes do not reuse prior missing confirmations" do
    remove_files
    scan
    Dir.mktmpdir("cci-new-root-") do |directory|
      configure_legacy_paths("zone_a" => directory)
      3.times { scan }
      assert_equal 1, @records.first.reload.filesystem_missing_scans
      assert_equal 10, Certificate.where(source: "filesystem").count
    end
  end

  test "healthy sources reconcile independently of an unavailable area" do
    second = Dir.mktmpdir("cci-second-source-")
    configure_legacy_paths("zone_a" => @directory, "zone_b" => second)
    10.times { |index| File.write(File.join(second, "cert-#{index}.pem"), @cert.to_pem) }
    scan
    second_record = Certificate.find_by!(area: "zone_b", source: "filesystem", source_id: "cert-0.pem#0")
    File.delete(File.join(second, "cert-0.pem"))
    configure_legacy_paths("zone_a" => File.join(@directory, "offline"), "zone_b" => second)
    2.times { assert_raises(Certificates::Error) { scan } }
    assert_not Certificate.exists?(second_record.id)
    assert_equal 10, Certificate.where(area: "zone_a", source: "filesystem").count
  ensure
    FileUtils.remove_entry(second) if second
  end

  test "cleanup failure rolls back deletion counters audit and discovered rows" do
    remove_files(@records.first(2))
    scan
    File.write(File.join(@directory, "new.pem"), @cert.to_pem)
    original = Certificate.instance_method(:destroy!)
    count = 0
    Certificate.define_method(:destroy!) do
      count += 1
      raise ActiveRecord::StatementInvalid, "synthetic cleanup interruption" if count == 2

      original.bind_call(self)
    end
    assert_raises(ActiveRecord::StatementInvalid) { scan }
    assert_equal 10, Certificate.where(source: "filesystem").count
    assert(@records.first(2).all? { |record| record.reload.filesystem_missing_scans == 1 })
    assert_empty AuditEvent.where(action: "delete")
    assert_not Certificate.exists?(source: "filesystem", source_id: "new.pem#0")
  ensure
    Certificate.define_method(:destroy!, original) if original
  end

  test "disabled reconciliation leaves missing counters intact" do
    remove_files
    scan
    FilesystemReconciliationConfiguration.instance_variable_set(:@configuration,
      @previous_settings.merge("enabled" => false))
    2.times { scan }
    assert_equal 1, @records.first.reload.filesystem_missing_scans
  end

  test "controlled approval requires confirmed exact IDs and records the responsible actor" do
    remove_files(@records.first(3))
    ids = @records.first(3).map(&:id)
    assert_raises(ArgumentError) { FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "operator") }
    2.times { scan }
    assert_raises(ArgumentError) do
      FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids.first(2), actor: "operator")
    end
    FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "operator")
    assert(ids.none? { |id| Certificate.exists?(id) })
    event = AuditEvent.find_by!(action: "delete")
    assert_equal "operator", event.actor
    assert event.details.fetch("approved")
    assert_equal 30.0, event.details.fetch("delete_percent")
    assert_equal ["operator"], AuditEvent.where(action: "delete").pluck(:actor)
    assert_raises(ArgumentError) { FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: ids, actor: "operator") }
    assert_equal 1, AuditEvent.where(action: "delete").count
  end

  test "reappearing files invalidate approval and roll back the fresh projection" do
    remove_files(@records.first(3))
    2.times { scan }
    File.write(File.join(@directory, "cert-0.pem"), @cert.to_pem)
    assert_raises(ArgumentError) do
      FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: @records.first(3).map(&:id), actor: "operator")
    end
    assert_equal 2, @records.first.reload.filesystem_missing_scans
    assert_empty AuditEvent.where(action: "delete")
    scan
    assert_equal 0, @records.first.reload.filesystem_missing_scans
    assert_equal 10, Certificate.where(source: "filesystem").count
  end

  test "newly confirmed candidates invalidate an approval instead of extending its ID set" do
    remove_files(@records.first(3))
    2.times { scan }
    remove_files([@records[3]])
    scan
    assert_raises(ArgumentError) do
      FilesystemReconciliation.approve!(area: "zone_a", certificate_ids: @records.first(3).map(&:id), actor: "operator")
    end
    assert_equal 1, @records[3].reload.filesystem_missing_scans
    assert_empty AuditEvent.where(action: "delete")
    assert_equal 10, Certificate.where(source: "filesystem").count
  end

  test "missing files do not repeatedly fail optional CA discovery" do
    remove_files
    scan
    snapshot = CaInventoryRefresh.new("zone_a").snapshot
    assert_equal 1, snapshot.fetch(:issues).size
    scan
    assert_not Certificate.exists?(@records.first.id)
  end
end
