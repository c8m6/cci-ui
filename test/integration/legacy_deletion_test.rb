# frozen_string_literal: true

require "test_helper"

class LegacyDeletionTest < ActionDispatch::IntegrationTest
  setup do
    @directory = Dir.mktmpdir
    configure_legacy_paths("zone_a" => @directory)
    @root, root_key = issue(name: "Bundle root", ca: true)
    cert, key = issue(name: "legacy.example.test", issuer: @root, issuer_key: root_key)
    @original = { "bundle.pem" => cert.to_pem + @root.to_pem, "bundle.key" => key.to_pem, "bundle.tag" => " production" }
    @original.each { |name, content| File.write(File.join(@directory, name), content) }
    CatalogIndexer.new.filesystem
    @record = Certificate.find_by!(source: "filesystem", source_id: "bundle.pem#0")
    post local_login_path, params: { identity: "zone_a_writer" }
  end

  teardown do
    configure_legacy_paths("zone_a" => TEST_LEGACY_ROOT)
    FileUtils.remove_entry(@directory)
  end

  def confirmation
    get delete_legacy_certificate_path(@record)
    assert_response :success
    css_select('input[name="deletion_token"]').first["value"]
  end

  def assert_original_files
    @original.each do |name, content|
      assert_equal content, File.binread(File.join(@directory, name))
      assert_not File.exist?(File.join(@directory, "#{name}.DELETED"))
    end
    assert_nil @record.reload.deleted_at
  end

  test "confirmation retires the entire bundle without removing bytes and keeps an audit record" do
    token = confirmation
    assert_includes response.body, "2 Zertifikate"
    assert_not_includes response.body, ".DELETED"
    assert_not_includes response.body, "umbenannt"
    assert_select 'input[name="confirm_delete"][required]'
    delete delete_legacy_certificate_path(@record), params: { deletion_token: token }
    assert_response :unprocessable_content
    assert_original_files
    assert_empty AuditEvent.where(action: "delete")

    delete delete_legacy_certificate_path(@record), params: { confirm_delete: "1", deletion_token: token }
    assert_redirected_to root_path
    @original.each do |name, content|
      assert_not File.exist?(File.join(@directory, name))
      assert_equal content, File.binread(File.join(@directory, "#{name}.DELETED"))
    end
    assert_equal 2, Certificate.where.not(deleted_at: nil).count
    assert_not @record.reload.active
    assert_equal "active", @record.rollout_status
    CatalogIndexer.run
    assert_equal 2, Certificate.where.not(deleted_at: nil).count
    get root_path, params: { q: "legacy", history: "1", archived: "1" }
    assert_select "tbody tr", count: 0
    get certificate_path(@record)
    assert_response :not_found
    post export_certificates_path, params: { ids: [@record.id], format_name: "pem" }
    assert_response :not_found
    event = AuditEvent.find_by!(action: "delete")
    assert_equal "succeeded", event.details.fetch("outcome")
    assert_equal 2, event.details.fetch("certificates").size
    assert_equal "bundle.pem.DELETED", event.details.fetch("files").fetch("bundle.pem")
    assert_not_includes event.details.to_json, "PRIVATE KEY"
    assert_equal "zone_a", event.area
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path
    assert_includes response.body, "bundle.key"
    assert_not_includes response.body, ".DELETED"
    assert_includes response.body, "Zertifikat gelöscht"
  end

  test "readers key exporters and writers from other areas cannot delete" do
    token = confirmation
    %w[zone_a_reader zone_a_exporter zone_b_writer].each do |identity|
      post local_login_path, params: { identity: identity }
      get delete_legacy_certificate_path(@record)
      assert_includes [303, 404], response.status
      delete delete_legacy_certificate_path(@record), params: { confirm_delete: "1", deletion_token: token }
      assert_includes [303, 404], response.status
      assert_original_files
    end
    assert_empty AuditEvent.where(action: "delete")
  end

  test "changed companion files expired tokens and forged confirmations cannot delete" do
    token = confirmation
    File.write(File.join(@directory, "bundle.tag"), "changed")
    delete delete_legacy_certificate_path(@record), params: { confirm_delete: "1", deletion_token: token }
    assert_nil @record.reload.deleted_at
    File.write(File.join(@directory, "bundle.tag"), @original.fetch("bundle.tag"))
    token = confirmation
    travel 16.minutes do
      delete delete_legacy_certificate_path(@record), params: { confirm_delete: "1", deletion_token: token }
      assert_original_files
    end
    delete delete_legacy_certificate_path(@record), params: { confirm_delete: "1", deletion_token: "forged" }
    assert_original_files
    assert_empty AuditEvent.where(action: "delete")
  end

  test "existing deleted files and symlinks are rejected without overwriting" do
    backup = File.join(@directory, "bundle.pem.DELETED")
    File.write(backup, "previous backup")
    assert_raises(Certificates::Error) { LegacyDeletion.new(@record).preview }
    assert_equal "previous backup", File.read(backup)
    File.unlink(backup)
    key = File.join(@directory, "bundle.key")
    File.rename(key, "#{key}.real")
    File.symlink("#{key}.real", key)
    assert_raises(Certificates::Error) { LegacyDeletion.new(@record).preview }
    assert_nil @record.reload.deleted_at
    assert File.exist?(File.join(@directory, "bundle.pem"))
  end

  test "a failed rename restores earlier files and records an uncertain outcome" do
    service = LegacyDeletion.new(@record)
    token = service.preview.fetch(:token)
    original_move = service.method(:move)
    service.define_singleton_method(:move) do |source, target|
      assert_event = AuditEvent.find_by!(action: "delete")
      raise "Missing intent" unless assert_event.details.fetch("outcome") == "pending"
      raise Errno::EROFS if source.end_with?("bundle.pem")

      original_move.call(source, target)
    end
    assert_raises(Certificates::Error) { service.call(token: token, actor: "operator") }
    assert_original_files
    assert_equal "unknown", AuditEvent.find_by!(action: "delete").details.fetch("outcome")
  end

  test "deleted records stay hidden even if files are manually restored and reindexed" do
    service = LegacyDeletion.new(@record)
    service.call(token: service.preview.fetch(:token), actor: "operator")
    @original.each_key do |name|
      File.rename(File.join(@directory, "#{name}.DELETED"), File.join(@directory, name))
    end
    CatalogIndexer.new.filesystem
    assert_equal 2, Certificate.where.not(deleted_at: nil).count
    assert_empty Certificate.visible_to(Identity.new(name: "writer", roles: ["zone_a_writer"]))
  end

  test "overlapping area roots and unavailable mounts do not authorize deletion" do
    configure_legacy_paths("zone_a" => @directory, "zone_b" => @directory)
    assert_raises(Certificates::Error) { LegacyDeletion.new(@record).preview }
    configure_legacy_paths("zone_a" => File.join(@directory, "unavailable"))
    assert_raises(Certificates::Error) { LegacyDeletion.new(@record).preview }
    assert_original_files
  end

  test "a PEM without companions can be deleted and CA snapshots are invalidated" do
    File.unlink(File.join(@directory, "bundle.key"))
    File.unlink(File.join(@directory, "bundle.tag"))
    snapshot = CaInventory.create!(area: "zone_a", checked_at: Time.current,
      authorities: [{ certificate_id: @record.id }])
    service = LegacyDeletion.new(@record)
    assert_equal ["bundle.pem"], service.preview.fetch(:files)
    service.call(token: service.preview.fetch(:token), actor: "operator")
    assert_nil snapshot.reload.checked_at
    assert_empty snapshot.authorities
    assert_empty CaInventoryRefresh.new("zone_a").snapshot.fetch(:authorities)
    assert_empty CaInventoryRefresh.new("zone_a").snapshot.fetch(:issues)
  end

  test "failure to persist the audit intent prevents all file changes" do
    service = LegacyDeletion.new(@record)
    token = service.preview.fetch(:token)
    original_create = AuditEvent.method(:create!)
    AuditEvent.define_singleton_method(:create!) { |**_attributes| raise ActiveRecord::StatementInvalid, "unavailable" }
    assert_raises(ActiveRecord::StatementInvalid) { service.call(token: token, actor: "operator") }
    assert_original_files
  ensure
    AuditEvent.define_singleton_method(:create!, original_create) if original_create
  end

  test "a concurrent destination creation cannot overwrite an existing backup" do
    service = LegacyDeletion.new(@record)
    token = service.preview.fetch(:token)
    original_move = service.method(:move)
    service.define_singleton_method(:move) do |source, target|
      File.write(target, "concurrent backup") if source.end_with?("bundle.key")
      original_move.call(source, target)
    end
    assert_raises(Certificates::Error) { service.call(token: token, actor: "operator") }
    assert_equal "concurrent backup", File.read(File.join(@directory, "bundle.key.DELETED"))
    @original.each { |name, content| assert_equal content, File.binread(File.join(@directory, name)) }
    assert_nil @record.reload.deleted_at
  end

  test "Consul records cannot use the filesystem deletion action" do
    record = store(issue.first)
    get delete_legacy_certificate_path(record)
    assert_response :see_other
    delete delete_legacy_certificate_path(record), params: { confirm_delete: "1", deletion_token: "forged" }
    assert_response :see_other
    assert_nil record.reload.deleted_at
    assert_empty AuditEvent.where(action: "delete")
  end
end
