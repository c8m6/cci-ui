# frozen_string_literal: true

# Generates and verifies PKCS#10 requests without shelling out or writing private files.
class CsrGeneration
  SUBJECTS = { "country" => "C", "state" => "ST", "locality" => "L", "organization" => "O",
               "organizational_unit" => "OU", "common_name" => "CN", "email" => "emailAddress" }.freeze
  CURVES = { 256 => "prime256v1", 384 => "secp384r1", 521 => "secp521r1" }.freeze

  def initialize(input)
    @input = CsrDefaults.values.merge(input.stringify_keys)
  end

  def generate
    fields = subject_fields
    sans = CsrNames.sans(fields.fetch("common_name"), @input["sans"])
    key = generate_key
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.new(fields.filter_map do |field, value|
      next if value.empty?

      [SUBJECTS.fetch(field), value, subject_type(field)]
    end)
    csr.public_key = key
    extension = OpenSSL::X509::ExtensionFactory.new.create_extension("subjectAltName", sans.join(","))
    extensions = OpenSSL::ASN1::Sequence([OpenSSL::ASN1.decode(extension.to_der)])
    csr.add_attribute(OpenSSL::X509::Attribute.new("extReq", OpenSSL::ASN1::Set([extensions])))
    digest = @input["digest"].to_s.upcase
    CsrNames.fail!(:algorithm) unless %w[SHA256 SHA384 SHA512].include?(digest)

    csr.sign(key, OpenSSL::Digest.new(digest))
    CsrNames.fail!(:generation) unless csr.verify(csr.public_key)

    { csr_pem: csr.to_pem, private_key: key.private_to_pem, common_name: fields.fetch("common_name"),
      sans: sans, subject_fields: fields, key_algorithm: @input["key_algorithm"].upcase, key_size: Integer(@input["key_size"]),
      digest: digest }
  rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
    CsrNames.fail!(:generation)
  end

  private

  def subject_type(field)
    return OpenSSL::ASN1::IA5STRING if field == "email"
    return OpenSSL::ASN1::PRINTABLESTRING if field == "country"

    OpenSSL::ASN1::UTF8STRING
  end

  def subject_fields
    fields = SUBJECTS.to_h { |field, _| [field, @input[field].to_s.strip] }
    CsrNames.name(fields.fetch("common_name"))
    CsrNames.fail!(:subject) if fields["common_name"].bytesize > 64
    CsrNames.fail!(:subject) unless fields.values.all? do |value|
      value.valid_encoding? && value.bytesize <= 200 && !value.match?(/[\x00-\x1f\x7f]/)
    end
    country = fields["country"]
    CsrNames.fail!(:subject) unless country.empty? || country.match?(/\A[A-Z]{2}\z/)
    email = fields["email"]
    CsrNames.fail!(:subject) unless email.empty? || email.match?(%r{\A[A-Za-z0-9.!#$%&'*+/=?^_~-]+@[A-Za-z0-9.-]+\z}x)

    fields
  end

  def generate_key
    size = Integer(@input["key_size"])
    case @input["key_algorithm"].to_s.upcase
    when "RSA"
      CsrNames.fail!(:algorithm) unless [2048, 3072, 4096].include?(size)
      OpenSSL::PKey::RSA.new(size)
    when "EC"
      CsrNames.fail!(:algorithm) unless CURVES.key?(size)
      OpenSSL::PKey::EC.generate(CURVES.fetch(size))
    else
      CsrNames.fail!(:algorithm)
    end
  end
end
