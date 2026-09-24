# frozen_string_literal: true

require "test_helper"

class CertificateChainViewTest < ActionDispatch::IntegrationTest
  setup do
    @root, @root_key = issue(name: "Root CA", ca: true, expired: true)
    @intermediate, @intermediate_key = issue(name: "Issuing CA", ca: true, issuer: @root, issuer_key: @root_key)
    @leaf, = issue(name: "service.example.test", issuer: @intermediate, issuer_key: @intermediate_key)
    post local_login_path, params: { identity: "zone_a_reader" }
  end

  test "details show root intermediate and selected certificate in issuer order with validity badges" do
    root_record = store(@root, certid: "root")
    issuer_record = store(@intermediate, certid: "issuer")
    record = store(@leaf, certid: "service")
    get certificate_path(record)
    assert_response :success
    assert_select ".certificate-chain" do
      assert_select "tr[data-depth='0']" do
        assert_select "a[href=?]", certificate_path(root_record)
        assert_select ".badge.danger", text: "Abgelaufen"
      end
      assert_select "tr[data-depth='1'] a[href=?]", certificate_path(issuer_record)
      assert_select "tr[data-depth='2'][aria-current=true]" do
        assert_select "a[href=?]", certificate_path(record)
      end
      assert_select "tr[data-depth]", count: 3
      assert_select "thead th", count: 3
      assert_select "td.mono", count: 0
      assert_includes response.body, I18n.t("ui.chain_complete", locale: :de)
    end
    assert_select ".detail-export", count: 0
    assert_select ".detail-grid-summary-only", count: 1
  end

  test "a missing root is shown as incomplete without relabeling the intermediate as root" do
    store(@intermediate, certid: "issuer")
    record = store(@leaf, certid: "service")
    get certificate_path(record)
    assert_response :success
    assert_select ".certificate-chain" do
      assert_select "tr[data-depth='0'] .badge", text: "Intermediate-CA"
      assert_select "tr[data-depth='1'][aria-current=true]", count: 1
      assert_includes response.body, I18n.t("ui.chain_incomplete", locale: :de)
    end
  end

  test "a single selected root is shown once and writer export controls remain available" do
    record = store(@root, certid: "root")
    post local_login_path, params: { identity: "zone_a_writer" }
    get certificate_path(record)
    assert_response :success
    assert_select ".certificate-chain tr[data-depth='0'][aria-current=true]", count: 1
    assert_select ".certificate-chain tr[data-depth]", count: 1
    assert_select ".detail-export", count: 1
  end
end
