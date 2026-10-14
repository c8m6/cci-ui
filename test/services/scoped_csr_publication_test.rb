# frozen_string_literal: true

require "test_helper"
require_relative "../support/csr_fixtures"

class ScopedCsrPublicationTest < ActiveSupport::TestCase
  include CsrFixtures

  setup do
    @tokens = ENV.fetch("CCI_CONSUL_TOKENS", nil)
    ENV["CCI_CONSUL_TOKENS"] = '{"zone_a":"synthetic-a","zone_b":"synthetic-b"}'
    @original_client = ConsulStore.method(:client)
    @identity = Identity.new(name: "scoped-csr", roles: %w[zone_a_csr zone_b_csr])
    @request = CsrWorkflow.create(csr_input.merge("areas" => %w[zone_a zone_b]), identity: @identity)
    @entry = CsrUpload.call(@request, data: issued_for(@request).to_pem, identity: @identity)
  end

  teardown do
    ENV["CCI_CONSUL_TOKENS"] = @tokens
    ConsulStore.define_singleton_method(:client, @original_client)
  end

  test "second area failure retains first area receipt and safely resumes without duplicate versions" do
    interrupt_second_area(after_commit: false)
    assert_equal "failed", publish.state
    assert ConsulStore.certid_snapshot("zone_a", "portal")
    assert_nil ConsulStore.certid_snapshot("zone_b", "portal")
    assert @entry.reload.prepared.any?
    ConsulStore.define_singleton_method(:client, @original_client)
    assert_equal "published", publish.state
    assert_equal "published", publish.state
    assert_versions_once
    assert_equal %w[zone_a zone_b], AuditEvent.where(action: "csr_publish").where("details ->> 'outcome' = 'succeeded'").pluck(:area).sort
  end

  test "lost second area response is recognized by exact immutable bytes" do
    interrupt_second_area(after_commit: true)
    assert_equal "failed", publish.state
    ConsulStore.define_singleton_method(:client, @original_client)
    assert_equal "published", publish.state
    assert_versions_once
    receipt = AuditEvent.where(action: "csr_publish", area: "zone_b").last
    assert_equal "succeeded", receipt.details.fetch("outcome")
    assert_equal "reconciled", receipt.details.fetch("code")
  end

  test "concurrent second area publication never overwrites immutable data or repeats the first area" do
    interrupt_second_area(after_commit: false)
    assert_equal "failed", publish.state
    ConsulStore.define_singleton_method(:client, @original_client)
    other = store(issue(name: "other.example.test").first, certid: "portal", area: "zone_b")
    assert_equal "failed", publish.state
    assert_equal "conflict", @entry.reload.error_code
    assert_equal ["zone_a"], @entry.prepared.fetch("areas").keys
    index = ConsulStore.certid_snapshot("zone_b", "portal").fetch(:index)
    assert_equal "published", publish(expected_indices: { "zone_a" => 0, "zone_b" => index }, confirm_overwrite: true).state
    assert_equal({ "zone_a" => 1, "zone_b" => 2 }, @entry.reload.consul_versions)
    assert_equal other.fingerprint,
      Certificates::Codec.fingerprint(OpenSSL::X509::Certificate.new(ConsulStore.get("zone_b", "portal/1")["pem"]))
  end

  private

  def publish(**) = CsrPublication.new(@entry, identity: @identity).call(**)

  def assert_versions_once
    %w[zone_a zone_b].each do |area|
      assert_equal 1, JSON.parse(ConsulStore.certid_snapshot(area, "portal").fetch(:value)).fetch("latest_version")
    end
    assert_equal({ "zone_a" => 1, "zone_b" => 1 }, @entry.reload.consul_versions)
  end

  def interrupt_second_area(after_commit:)
    original = @original_client
    ConsulStore.define_singleton_method(:client) do |area = nil|
      connection = original.call(area)
      if area == "zone_b"
        transaction = connection.method(:transaction)
        connection.define_singleton_method(:transaction) do |operations|
          transaction.call(operations) if after_commit
          raise ConsulConnection::Error, "simulated area failure"
        end
      end
      connection
    end
  end
end
