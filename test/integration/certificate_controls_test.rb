# frozen_string_literal: true

require "test_helper"

class CertificateControlsTest < ActionDispatch::IntegrationTest
  setup do
    @record = store(issue.first)
    post local_login_path, params: { identity: "zone_a_writer" }
  end

  def preview(certid: "test", serial: 2, areas: ["zone_a"])
    post imports_path, params: { areas: areas, pem: issue(serial: serial).first.to_pem, certid: certid }
    assert_response :success
    Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
  end

  test "existing certid requires explicit confirmation enforced by server" do
    token = preview
    assert_select 'input[name="confirm_overwrite"][required]', count: 1
    assert_includes response.body, "Bisherige Version: #{@record.certificate_version}"
    post imports_path, params: { token: token }
    assert_response :unprocessable_content
    assert ImportDraft.exists?(token: token)
    assert_equal @record.certificate_version, JSON.parse(ConsulStore.status_snapshot(@record)[:value])["active_version"]
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_redirected_to root_path
    assert_not @record.reload.active
    assert_equal 2, Certificate.where(area: "zone_a").count
    assert_not ImportDraft.exists?(token: token)
  end

  test "invalid certid is rejected before reading destination data" do
    post imports_path,
      params: { areas: ["zone_a"], pem: issue(serial: 2).first.to_pem, certid: "../zone_b/keys/secret" }
    assert_response :see_other
    assert_equal 0, ImportDraft.count
  end

  test "old drafts require a new preview" do
    token = preview
    draft = ImportDraft.find_by!(token: token)
    payload = JSON.parse(draft.payload)
    payload["entries"].each { |entry| entry.delete("certid_index") }
    draft.update!(payload: JSON.generate(payload))
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_response :see_other
    assert_equal 1, Certificate.count
    assert @record.reload.active
  end

  test "new certid has no overwrite prompt" do
    token = preview(certid: "new")
    assert_select 'input[name="confirm_overwrite"][required]', count: 0
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert_equal "active", Certificate.find_by!(certid: "new").rollout_status
  end

  test "concurrent renewal requires fresh preview even after confirmation" do
    token = preview
    concurrent = store(issue(serial: 3).first)
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_response :unprocessable_content
    assert_includes response.body, "seit der Vorschau geändert"
    assert_equal 2, Certificate.count
    assert concurrent.reload.active
  end

  test "certid created after preview cannot be silently overwritten" do
    token = preview(certid: "new")
    concurrent = store(issue(serial: 3).first, certid: "new")
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_response :unprocessable_content
    assert concurrent.reload.active
    assert_equal 2, Certificate.count
  end

  test "multi area preview confirms only existing area certid and preserves status" do
    ConsulStore.set_status(@record.area, @record.source_id, status: "norollout", actor: "test",
      expected_certid_index: ConsulStore.status_snapshot(@record)[:index])
    post local_login_path, params: { identity: "all:writer" }
    token = preview(areas: %w[zone_a zone_b])
    assert_select ".preview-entry .flash-error", count: 1
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_redirected_to root_path
    assert_equal "norollout", Certificate.find_by!(area: "zone_a", active: true).rollout_status
    assert_equal "active", Certificate.find_by!(area: "zone_b", active: true).rollout_status
  end

  test "writer changes status and readers can filter but cannot edit" do
    get certificate_path(@record)
    assert_select 'select[name="rollout_status"]', count: 1
    index = Nokogiri::HTML(response.body).at_css('input[name="certid_index"]')["value"]
    patch certificate_path(@record), params: { rollout_status: "delete", certid_index: index }
    assert_redirected_to certificate_path(@record)
    assert_equal "delete", @record.reload.rollout_status
    get root_path, params: { rollout_status: "delete", status: "valid", q: "portal" }
    assert_select "tbody tr", count: 1
    get root_path, params: { rollout_status: "active" }
    assert_select "tbody tr", count: 0
    patch certificate_path(@record), params: { rollout_status: "active", certid_index: index }
    assert_response :see_other
    assert_equal "delete", @record.reload.rollout_status
    post local_login_path, params: { identity: "zone_a_reader" }
    get certificate_path(@record)
    assert_select 'select[name="rollout_status"]', count: 0
    assert_includes response.body, "delete"
    patch certificate_path(@record),
      params: { rollout_status: "active", certid_index: ConsulStore.status_snapshot(@record)[:index] }
    assert_response :see_other
    assert_equal "delete", @record.reload.rollout_status
    hidden = store(issue(serial: 7).first, area: "zone_b")
    patch certificate_path(hidden),
      params: { rollout_status: "delete", certid_index: ConsulStore.status_snapshot(hidden)[:index] }
    assert_response :not_found
    assert_equal "active", hidden.reload.rollout_status
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path, params: { event_action: "status_change" }
    assert_select "tbody tr", count: 1
    assert_includes response.body, "Puppet-Status geändert"
    assert_includes response.body, "delete"
  end

  test "filesystem writer cannot change Puppet status or archive" do
    previous = AreaConfiguration.configuration
    Dir.mktmpdir do |dir|
      configure_legacy_paths("zone_a" => dir)
      path = File.join(dir, "legacy.pem")
      content = issue(serial: 8).first.to_pem
      File.write(path, content)
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      get certificate_path(record)
      assert_response :success
      assert_select 'input[name="certid_index"]', count: 0
      assert_select 'select[name="rollout_status"]', count: 0
      assert_select "a", text: "Archivieren", count: 0
      patch certificate_path(record), params: { rollout_status: "norollout", certid_index: "0" }
      assert_response :see_other
      assert_equal "active", record.reload.rollout_status
      assert_equal content, File.read(path)
      get root_path, params: { rollout_status: "norollout", source: "filesystem" }
      assert_select "tbody tr", count: 0
      get root_path, params: { rollout_status: "active", source: "filesystem" }
      assert_select "tbody tr", count: 0
      patch certificate_path(record)
      assert_response :see_other
      assert_equal content, File.read(path)
    end
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end
end
