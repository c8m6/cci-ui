# frozen_string_literal: true

module CsrFixtures
  def csr_identity(area = "zone_a") = Identity.new(name: "csr-test", roles: ["#{area}_csr"])

  def csr_input
    { "area" => "zone_a", "certid" => "portal", "common_name" => "portal.example.test",
      "sans" => "www.example.test,192.0.2.7", "key_algorithm" => "RSA", "key_size" => "2048", "digest" => "SHA256" }
  end

  def create_csr(**overrides)
    CsrWorkflow.create(csr_input.merge(overrides.stringify_keys), identity: csr_identity(overrides.fetch(:area, "zone_a")))
  end

  def issued_for(request, issuer: nil, issuer_key: nil, serial: 1, sans: request.sans, common_name: request.common_name)
    csr = OpenSSL::X509::Request.new(request.csr_pem)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.new([["CN", common_name]])
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = csr.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    factory = OpenSSL::X509::ExtensionFactory.new
    cert.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
    cert.add_extension(factory.create_extension("subjectAltName", sans.join(",")))
    cert.sign(issuer_key || OpenSSL::PKey.read(CsrSecrets.decrypt(request, "key")), OpenSSL::Digest.new("SHA256"))
    cert
  end

  def upload_csr(request, cert = issued_for(request), **)
    CsrUpload.call(request, data: cert.to_pem, identity: csr_identity(request.area), **)
  end
end
