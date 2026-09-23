# frozen_string_literal: true

require "test_helper"

class CertificateArchivingFlowTest < ActionDispatch::IntegrationTest
  setup do
    @record = store(issue.first)
    post local_login_path, params: { identity: "zone_a_writer" }
  end

  def archive_params(record = @record)
    { archive: "1", confirm_archive: "1", certid_index: ConsulStore.status_snapshot(record)&.fetch(:index) || 0 }
  end

  test "archive confirmation is enforced and result remains searchable and audited" do
    get certificate_path(@record)
    assert_select ".status-actions" do
      assert_select 'input[type="submit"][value="Status speichern"]'
      assert_select "a", text: "Archivieren"
    end
    assert_select "button", text: "Löschen", count: 0
    get archive_certificate_path(@record)
    assert_response :success
    assert_select 'input[name="confirm_archive"][required]', count: 1
    assert_includes response.body, "alle Versionen der CertID"
    assert_includes response.body, "Dienste können dadurch ausfallen"
    params = archive_params
    patch certificate_path(@record), params: params.except(:confirm_archive)
    assert_response :unprocessable_content
    assert_not @record.reload.archived
    assert_empty AuditEvent.where(action: "archive")
    patch certificate_path(@record), params: params
    assert_redirected_to certificate_path(@record)
    assert @record.reload.archived
    assert_equal "delete", @record.rollout_status
    follow_redirect!
    assert_response :success
    assert_select 'select[name="rollout_status"]', count: 0
    patch certificate_path(@record),
      params: { rollout_status: "active", certid_index: ConsulStore.status_snapshot(@record)[:index] }
    assert_response :see_other
    assert @record.reload.archived
    assert_equal "delete", @record.rollout_status
    get root_path
    assert_select "tbody tr", count: 0
    assert_select ".stat-card strong", text: "0", count: 3
    get root_path, params: { q: "portal" }
    assert_select "tbody tr", count: 1
    assert_select ".badge", text: "Archiviert"
    get root_path, params: { archived: "1" }
    assert_select "tbody tr", count: 1
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path, params: { event_action: "archive" }
    assert_select "tbody tr", count: 1
    assert_includes response.body, "Zertifikat archiviert"
    assert_includes response.body, "Archivierung bestätigt"
    assert_includes response.body, "Alle Versionen der CertID"
  end

  test "reader and foreign area writer cannot archive and the delete route is removed" do
    post local_login_path, params: { identity: "zone_a_reader" }
    get certificate_path(@record)
    assert_select "a", text: "Archivieren", count: 0
    get archive_certificate_path(@record)
    assert_response :see_other
    patch certificate_path(@record), params: archive_params
    assert_response :see_other
    assert_not @record.reload.archived
    post local_login_path, params: { identity: "zone_b_writer" }
    get archive_certificate_path(@record)
    assert_response :not_found
    patch certificate_path(@record), params: archive_params
    assert_response :not_found
    post local_login_path, params: { identity: "zone_a_writer" }
    delete certificate_path(@record)
    assert_response :not_found
    assert Certificate.exists?(@record.id)
    assert ConsulStore.get(@record.area, @record.source_id)
    assert_empty AuditEvent.where(action: "archive")
  end

  test "concurrent renewal invalidates the archive confirmation" do
    params = archive_params
    newer = store(issue(serial: 2).first)
    patch certificate_path(@record), params: params
    assert_response :see_other
    assert_not @record.reload.archived
    assert_not newer.reload.archived
    assert_empty AuditEvent.where(action: "archive")
  end

  test "absent filesystem material still allows viewing but no archiving" do
    previous = AreaConfiguration.configuration
    Dir.mktmpdir do |dir|
      configure_legacy_paths("zone_a" => dir)
      path = File.join(dir, "legacy.pem")
      File.write(path, issue(serial: 2).first.to_pem)
      CatalogIndexer.run
      record = Certificate.find_by!(source: "filesystem")
      File.delete(path)
      CatalogIndexer.run
      get certificate_path(record)
      assert_response :success
      assert_includes response.body, "Quelldaten nicht verfügbar"
      assert_includes response.body, record.fingerprint
      assert_select "a", text: "Archivieren", count: 0
      get archive_certificate_path(record)
      assert_response :see_other
      patch certificate_path(record), params: archive_params(record)
      assert_response :see_other
      assert_not record.reload.archived
      assert_equal "active", record.rollout_status
      assert_empty AuditEvent.where(action: "archive")
      assert_nil ConsulStore.status_snapshot(record)
    end
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end
end
