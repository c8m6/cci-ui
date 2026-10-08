# frozen_string_literal: true

require "test_helper"
require_relative "../support/puppet_acme_fixture"

class IssuerImportTest < ActiveSupport::TestCase
  include PuppetAcmeFixture

  def issuer(serial: 1, name: "R11")
    cert, key = issue(name: name, ca: true, serial: serial)
    cert.not_after = Time.utc(2027, 3, 12)
    cert.sign(key, "SHA256")
    cert
  end

  def preview(*certs, certid: "")
    CertificateImport.preview(files: [], pem: certs.map(&:to_pem).join, password: "", areas: ["zone_a"],
      tags: "", certid: certid, owner: "issuer-test")
  end

  def commit(token, **)
    CertificateImport.commit(token: token, owner: "issuer-test",
      identity: Identity.new(name: "issuer-test", roles: ["zone_a_writer"]), **)
  end

  test "CA naming decodes all supported ASN1 strings and agrees with the shared convention" do
    cert = issuer
    assert_equal "r11_2027-03-12", Certificates::Codec.issuer_certid(cert)
    [[OpenSSL::ASN1::UTF8STRING, "UTF-8"], [OpenSSL::ASN1::BMPSTRING, "UTF-16BE"],
      [OpenSSL::ASN1::UNIVERSALSTRING, "UTF-32BE"], [OpenSSL::ASN1::T61STRING, "ISO-8859-1"]].each do |type, encoding|
      cert.subject = OpenSSL::X509::Name.new([["CN", "--Müller R11--".encode(encoding), type]])
      assert_equal "m-ller-r11_2027-03-12", Certificates::Codec.issuer_certid(cert)
      assert_equal "Müller", Certificates::Codec.name_text("Müller", type), "already decoded JRuby string"
    end
    cert.subject = OpenSSL::X509::Name.new([%w[O ISRG-Root-X1]])
    cert.not_after = Time.utc(2035, 6, 4)
    assert_equal "isrg-root-x1_2035-06-04", Certificates::Codec.issuer_certid(cert)
    cert.subject = OpenSSL::X509::Name.new([%w[CN !!!], %w[O Ignored]])
    assert_equal "ca_2035-06-04", Certificates::Codec.issuer_certid(cert)
    cert.subject = OpenSSL::X509::Name.new([])
    assert_equal "ca_2035-06-04", Certificates::Codec.issuer_certid(cert)
    cert.subject = OpenSSL::X509::Name.new([["CN", "#{"A" * 99} B"], %w[CN Ignored]])
    assert_equal "#{"a" * 99}-_2035-06-04", Certificates::Codec.issuer_certid(cert)
    assert_equal 120, Certificates::Codec.issuer_certid_alternative(cert).length
  end

  test "new bundle assigns CA names but leaves automatic leaf fingerprints unchanged" do
    ca = issuer
    leaf = issue.first
    token, data = preview(leaf, ca)
    names = data.fetch("entries").map { |entry| entry.fetch("certid") }
    assert_equal [Certificates::Codec.fingerprint(leaf), "r11_2027-03-12"], names
    successes, errors = commit(token)
    assert_empty errors
    assert_equal names.map { |name| "#{name}/1" }, successes
    assert_equal 2, Certificate.count
  end

  test "explicit CA and leaf certids retain normal version import behavior" do
    [issuer, issue.first].each_with_index do |cert, index|
      name = "explicit-#{index}"
      record = store(cert, certid: name)
      token, data = preview(cert, certid: name)
      assert_nil data.fetch("entries").first["reuse_version"]
      assert_equal [["#{name}/2"], []], commit(token, confirm_overwrite: true)
      assert_not record.reload.active
    end
  end

  test "existing Puppet issuer is reused without new versions metadata or audit writes" do
    cert = issuer
    record = publish_puppet_acme(cert: cert, certid: "r11_2027-03-12", renewal: false)
    before = ConsulStore.status_snapshot(record)
    token, data = preview(cert)
    assert_equal 1, data.fetch("entries").first.fetch("reuse_version")
    assert_no_difference ["Certificate.count", "AuditEvent.count"] do
      assert_equal [["r11_2027-03-12/1"], []], commit(token)
    end
    assert_equal before, ConsulStore.status_snapshot(record)
    assert_equal "puppet", record.reload.client
  end

  test "a real intermediate from Puppet is reused and the imported leaf still assembles its chain" do
    root, root_key = issue(name: "Test Root", ca: true)
    intermediate, intermediate_key = issue(name: "R11", ca: true, issuer: root, issuer_key: root_key)
    intermediate.not_after = Time.utc(2027, 3, 12)
    intermediate.sign(root_key, "SHA256")
    leaf, = issue(issuer: intermediate, issuer_key: intermediate_key)
    publish_puppet_acme(cert: intermediate, certid: "r11_2027-03-12", renewal: false)
    token, = preview(leaf, intermediate, root)
    successes, errors = commit(token)
    assert_empty errors
    assert_equal 3, successes.size
    assert_equal 3, Certificate.count
    assert_equal 1, Certificate.where(certid: "r11_2027-03-12").count
    leaf_record = Certificate.find_by!(fingerprint: Certificates::Codec.fingerprint(leaf))
    material = CertificateMaterial.with_chain(leaf_record, CertificateMaterial.load(leaf_record),
      Identity.new(name: "reader", roles: ["zone_a_reader"]))
    assert_equal [intermediate.to_der, root.to_der], material.fetch(:chain).map(&:to_der)
  end

  test "different issuers with identical subject and expiry receive primary and fingerprint alternative" do
    first = issuer
    second = issuer(serial: 2)
    token, data = preview(first, second)
    alternative = "r11_2027-03-12_#{Certificates::Codec.fingerprint(second)[0, 8]}"
    assert_equal(["r11_2027-03-12", alternative], data.fetch("entries").map { |entry| entry.fetch("certid") })
    assert_equal [["r11_2027-03-12/1", "#{alternative}/1"], []], commit(token)
    token, data = preview(second)
    assert_equal alternative, data.fetch("entries").first.fetch("certid")
    assert_equal [["#{alternative}/1"], []], commit(token)
    assert_equal 2, Certificate.count
  end

  test "collision with both stored names fails without changing any existing material" do
    cert = issuer
    primary = store(issuer(serial: 2), certid: Certificates::Codec.issuer_certid(cert))
    alternate = store(issuer(serial: 3), certid: Certificates::Codec.issuer_certid_alternative(cert))
    before = [primary, alternate].map { |record| ConsulStore.status_snapshot(record) }
    assert_no_difference ["Certificate.count", "ImportDraft.count", "AuditEvent.count"] do
      error = assert_raises(Certificates::Error) { preview(cert) }
      assert_equal I18n.t("errors.app.issuer_collision", certid: primary.certid), error.message
    end
    assert_equal(before, [primary, alternate].map { |record| ConsulStore.status_snapshot(record) })
  end

  test "identical alternative takes precedence over free primary and legacy fingerprints are untouched" do
    cert = issuer
    legacy = store(cert, certid: Certificates::Codec.fingerprint(cert))
    alternate = store(cert, certid: Certificates::Codec.issuer_certid_alternative(cert))
    token, data = preview(cert)
    assert_equal alternate.certid, data.fetch("entries").first.fetch("certid")
    assert_equal [[alternate.source_id], []], commit(token)
    assert legacy.reload.active
    assert_equal 2, Certificate.count
  end

  test "concurrent issuer creation or changed reuse selection requires a fresh preview" do
    cert = issuer
    token, = preview(cert)
    record = store(issuer(serial: 2), certid: Certificates::Codec.issuer_certid(cert))
    successes, errors = commit(token)
    assert_empty successes
    assert_equal 1, errors.size
    assert_equal 1, Certificate.count
    token, = preview(OpenSSL::X509::Certificate.new(ConsulStore.get(record.area, record.source_id).fetch("pem")))
    ConsulStore.set_status(record.area, record.source_id, status: "norollout", actor: "other",
      expected_certid_index: ConsulStore.status_snapshot(record).fetch(:index))
    successes, errors = commit(token)
    assert_empty successes
    assert_equal 1, errors.size
    assert_equal 1, Certificate.count
  end
end
