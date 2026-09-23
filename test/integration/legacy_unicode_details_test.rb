# frozen_string_literal: true

require "test_helper"

class LegacyUnicodeDetailsTest < ActionDispatch::IntegrationTest
  test "legacy details render UTF8 issuer and subject in usable Hiera YAML" do
    previous = AreaConfiguration.configuration
    Dir.mktmpdir("cci-unicode-details-") do |directory|
      configure_legacy_paths("zone_a" => directory)
      # Keep DNS SANs ASCII while using real UTF8String attributes in both DNs.
      issuer, issuer_key = issue(name: "issuer.example.test", ca: true)
      issuer.subject = OpenSSL::X509::Name.new([["CN", "Müller CA"], ["O", "Test"]])
      issuer.issuer = issuer.subject
      issuer.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
      cert, = issue(name: "portal.example.test", issuer: issuer, issuer_key: issuer_key)
      cert.subject = OpenSSL::X509::Name.new([["CN", "Büro 東京"], ["O", "Test"]])
      cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
      File.write(File.join(directory, "unicode.pem"), cert.to_pem)
      File.write(File.join(directory, "unicode.tag"), "_Prüfung")
      CatalogIndexer.new.filesystem
      record = Certificate.find_by!(source: "filesystem")
      assert_equal "Büro 東京", record.common_name
      post local_login_path, params: { identity: "zone_a_reader" }
      get certificate_path(record)
      assert_response :success
      document = Nokogiri::HTML(response.body)
      snippet = document.at_xpath('//section[h2[text()="Hiera-Konfiguration"]]/pre').text
      parsed = YAML.safe_load(snippet)
      assert_equal 'CN=M\xC3\xBCller CA, O=Test', parsed.fetch("issuer")
      assert_equal 'CN=B\xC3\xBCro \xE6\x9D\xB1\xE4\xBA\xAC, O=Test_Prüfung', parsed.fetch("subject")
      assert_not_includes snippet, "\uFFFD"
    end
  ensure
    AreaConfiguration.instance_variable_set(:@configuration, previous)
  end
end
