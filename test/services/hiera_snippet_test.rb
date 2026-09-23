# frozen_string_literal: true

require "test_helper"

class HieraSnippetTest < ActiveSupport::TestCase
  test "binary UTF8 name values retain their byte escapes" do
    name = OpenSSL::X509::Name.new([["CN", "Müller 東京", OpenSSL::ASN1::UTF8STRING]])
    value = name.to_a.first[1]
    assert_equal Encoding::BINARY, value.encoding
    assert_equal 'CN=M\xC3\xBCller \xE6\x9D\xB1\xE4\xBA\xAC', HieraSnippet.legacy_dn(name)
    assert_equal "Müller 東京".b, value
  end

  test "non UTF8 ASN1 bytes remain exact instead of being replaced" do
    name = OpenSSL::X509::Name.new([["CN", "Müller".encode("ISO-8859-1"), OpenSSL::ASN1::T61STRING]])
    assert_equal 'CN=M\xFCller', HieraSnippet.legacy_dn(name)
  end

  test "display names decode ASN1 encodings while Hiera retains original bytes" do
    [
      [OpenSSL::ASN1::UTF8STRING, "UTF-8"],
      [OpenSSL::ASN1::T61STRING, "ISO-8859-1"],
      [OpenSSL::ASN1::BMPSTRING, "UTF-16BE"],
      [OpenSSL::ASN1::UNIVERSALSTRING, "UTF-32BE"]
    ].each do |type, encoding|
      name = OpenSSL::X509::Name.new([["CN", "Müller".encode(encoding), type]])
      original = name.to_der
      assert_equal "Müller", Certificates::Codec.common_name(name)
      assert_equal Encoding::UTF_8, Certificates::Codec.common_name(name).encoding
      assert_equal original, name.to_der
      assert HieraSnippet.legacy_dn(name).ascii_only?
    end
    assert_equal "No common name", Certificates::Codec.common_name(OpenSSL::X509::Name.new([%w[O Example]]))
  end

  test "ASCII separators and URI punctuation retain legacy formatting" do
    name = OpenSSL::X509::Name.new([
      ["CN", 'Example "CA" %'], ["O", "Example / Test & Co."],
      ["serialNumber", "123"], ["postalCode", "10115"], ["emailAddress", "admin@example.test"]
    ])
    assert_equal 'CN=Example \x22CA\x22 \x25, O=Example / Test & Co./serialNumber=123/postalCode=10115/emailAddress=admin@example.test',
      HieraSnippet.legacy_dn(name)
  end
end
