# frozen_string_literal: true

require "test_helper"

class CertificateAreaConfigurationTest < ActiveSupport::TestCase
  test "multiple is the default and accepts several configured areas" do
    assert_equal "multiple", CertificateAreaConfiguration.mode({})
    assert_equal "multiple", CertificateAreaConfiguration.mode("CCI_CERTIFICATE_AREA_MODE" => " ")
    assert_equal %w[zone_a zone_b], CertificateAreaConfiguration.validate_selection!(%w[zone_a zone_b], {})
  end

  test "single accepts exactly one configured area" do
    environment = { "CCI_CERTIFICATE_AREA_MODE" => "single" }
    assert_equal ["zone_a"], CertificateAreaConfiguration.validate_selection!(["zone_a"], environment)
    assert_raises(Certificates::Error) do
      CertificateAreaConfiguration.validate_selection!(%w[zone_a zone_b], environment)
    end
  end

  test "invalid modes and areas fail closed" do
    assert_raises(ArgumentError) do
      CertificateAreaConfiguration.mode("CCI_CERTIFICATE_AREA_MODE" => "either")
    end
    assert_raises(Certificates::Error) do
      CertificateAreaConfiguration.validate_selection!(["unknown"], {})
    end
  end

  test "single mode rejects a fingerprint already retained in another area" do
    cert, = issue
    store(cert, area: "zone_a", certid: "existing")
    environment = { "CCI_CERTIFICATE_AREA_MODE" => "single" }
    fingerprint = Certificates::Codec.fingerprint(cert)

    assert_raises(Certificates::Error) do
      CertificateAreaConfiguration.validate_fingerprint!(fingerprint, areas: ["zone_b"], environment: environment)
    end
    assert_nothing_raised do
      CertificateAreaConfiguration.validate_fingerprint!(fingerprint, areas: ["zone_a"], environment: environment)
    end
  end
end
