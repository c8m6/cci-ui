# frozen_string_literal: true

require "test_helper"
require_relative "../support/puppet_acme_fixture"

class PuppetAcmeCompatibilityTest < ActionDispatch::IntegrationTest
  include PuppetAcmeFixture

  setup do
    @cert, @key = issue(name: "www.example.test")
    @record = publish_puppet_acme(cert: @cert, key: @key)
    post local_login_path, params: { identity: "zone_a_writer" }
  end

  test "module documents index as Consul Puppet material and display live renewal metadata" do
    assert_equal "consul", @record.source
    assert_equal "puppet", @record.client
    assert_equal "puppet", @record.renewal_mode
    assert_equal "puppet:worker.example.test", @record.created_by
    assert_equal @key.public_to_der, CertificateMaterial.load(@record, private_key: true).fetch(:key).public_to_der
    get certificate_path(@record)
    assert_response :success
    assert_select "dd", text: "Automatisch durch Puppet / ACME"
    assert_select "dd", text: "www.example.test"
    assert_includes response.body, "puppet:worker.example.test"
    assert_includes response.body, I18n.t("ui.automated_warning")
    refute_includes response.body, @key.private_to_pem
    refute @record.attributes.key?("acme_renewal")

    snapshot = ConsulStore.status_snapshot(@record)
    metadata = JSON.parse(snapshot.fetch(:value))
    metadata.delete("acme_renewal")
    ConsulStore.client.transaction([ConsulConnection.set("#{ConsulStore.prefix(@record.area)}/certids/#{@record.certid}",
      metadata, index: snapshot.fetch(:index))])
    get certificate_path(@record)
    assert_response :success
    refute_includes response.body, I18n.t("ui.automated_management")
    refute_includes response.body, I18n.t("ui.automated_warning")
  end

  test "status import activation and archive preserve external metadata exactly" do
    snapshot = ConsulStore.status_snapshot(@record)
    original = JSON.parse(snapshot.fetch(:value)).merge("future_writer" => { "nested" => [true, nil, 7, "unchanged"] })
    original.fetch("acme_renewal")["future_field"] = { "retained" => [1, 2] }
    ConsulStore.client.transaction([ConsulConnection.set("#{ConsulStore.prefix(@record.area)}/certids/#{@record.certid}",
      original, index: snapshot.fetch(:index))])
    immutable = ConsulStore.get(@record.area, @record.source_id)

    %w[norollout delete active].each do |status|
      patch certificate_path(@record), params: { rollout_status: status,
                                                 certid_index: ConsulStore.status_snapshot(@record).fetch(:index) }
      assert_response :see_other
      assert_equal status, acme_metadata(@record).fetch("status")
      assert_preserved(original)
    end

    post imports_path, params: { areas: ["zone_a"], pem: issue(serial: 2).first.to_pem, certid: @record.certid }
    assert_response :success
    assert_includes response.body, I18n.t("ui.automated_warning")
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    refute_includes ImportDraft.find_by!(token: token).payload, "acme_renewal"
    post imports_path, params: { token: token, confirm_overwrite: "1" }
    assert_redirected_to root_path
    assert_equal 2, acme_metadata(@record).fetch("active_version")
    assert_preserved(original)

    get certificate_path(@record)
    assert_response :success
    assert_select "button[data-turbo-confirm]" do |buttons|
      assert(buttons.any? { |button| button["data-turbo-confirm"].include?(I18n.t("ui.automated_warning")) })
    end
    patch certificate_path(@record)
    assert_response :see_other
    assert_equal 1, acme_metadata(@record).fetch("active_version")
    assert_preserved(original)
    assert_equal immutable, ConsulStore.get(@record.area, @record.source_id)

    patch certificate_path(@record), params: { archive: "1", confirm_archive: "1",
                                               certid_index: ConsulStore.status_snapshot(@record).fetch(:index) }
    assert_response :see_other
    assert_equal true, acme_metadata(@record).fetch("archived")
    assert_equal "delete", acme_metadata(@record).fetch("status")
    assert_preserved(original)
    assert @record.reload.archived
  end

  test "Zabbix endpoint retains Puppet classification and exposes no extension metadata" do
    previous = ENV.to_h.slice("CCI_ZABBIX_INTEGRATION_ENABLED", "CCI_ZABBIX_INTEGRATION_TOKEN")
    ENV["CCI_ZABBIX_INTEGRATION_ENABLED"] = "true"
    ENV["CCI_ZABBIX_INTEGRATION_TOKEN"] = "synthetic-acme-monitoring-token"
    get "/integrations/zabbix", headers: { "Authorization" => "Bearer #{ENV.fetch("CCI_ZABBIX_INTEGRATION_TOKEN")}" }
    assert_response :success
    entry = response.parsed_body.fetch("certificates").find { |row| row.fetch("id") == @record.id }
    assert_equal "puppet", entry.fetch("renewal")
    refute_match(/acme|worker|private|issuers|domains/, response.body)
  ensure
    %w[CCI_ZABBIX_INTEGRATION_ENABLED CCI_ZABBIX_INTEGRATION_TOKEN].each { |name| ENV[name] = previous[name] }
  end

  test "bundle preview clearly distinguishes existing issuer reuse from version replacement" do
    cert, = issue(name: "Test CA", ca: true)
    certid = Certificates::Codec.issuer_certid(cert)
    publish_puppet_acme(cert: cert, certid: certid, renewal: false)
    post imports_path, params: { areas: ["zone_a"], pem: cert.to_pem }
    assert_response :success
    assert_includes response.body, I18n.t("ui.issuer_reused", version: 1)
    assert_select 'input[name="confirm_overwrite"]', count: 0
    token = Nokogiri::HTML(response.body).at_css('input[name="token"]')["value"]
    post imports_path, params: { token: token }
    assert_redirected_to root_path
    assert_equal 1, Certificate.where(certid: certid).count
  end

  test "external public text is escaped and malformed summaries still allow safe viewing" do
    metadata = acme_metadata(@record)
    metadata["acme_renewal"]["domains"] = ["<script>alert('example')</script>"]
    metadata["acme_renewal"]["unrecognized"] = "never-render-this-field"
    path = "#{ConsulStore.prefix(@record.area)}/certids/#{@record.certid}"
    ConsulStore.client.transaction([ConsulConnection.set(path, metadata,
      index: ConsulStore.status_snapshot(@record).fetch(:index))])
    get certificate_path(@record)
    assert_response :success
    assert_select "script", text: "alert('example')", count: 0
    assert_includes response.body, "&lt;script&gt;"
    refute_includes response.body, "never-render-this-field"
    metadata["acme_renewal"] = "malformed"
    ConsulStore.client.transaction([ConsulConnection.set(path, metadata,
      index: ConsulStore.status_snapshot(@record).fetch(:index))])
    get certificate_path(@record)
    assert_response :success
    refute_includes response.body, I18n.t("ui.automated_management")
    assert_includes response.body, I18n.t("ui.automated_warning")
  end

  private

  def assert_preserved(original)
    current = acme_metadata(@record)
    %w[acme_renewal future_writer].each do |field|
      assert_equal original.fetch(field), current.fetch(field)
      assert_equal JSON.generate(original.fetch(field)), JSON.generate(current.fetch(field))
    end
  end
end
