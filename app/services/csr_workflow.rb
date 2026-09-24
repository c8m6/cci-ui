# frozen_string_literal: true

# Owns local CSR creation and disclosure independently of Consul availability.
class CsrWorkflow
  def self.authorize!(identity, area)
    CsrNames.fail!(:forbidden) unless identity.csr?(area)
  end

  def self.create(input, identity:)
    area = input.fetch("area", "")
    authorize!(identity, area)
    ConsulStore.validate_certid!(input["certid"])
    Certificates::Vault.key(area)
    comment = input.fetch("comment", "").to_s
    CsrNames.fail!(:subject) if comment.length > 2000

    material = CsrGeneration.new(input).generate
    key = material.delete(:private_key)
    request = CertificateRequest.new(material.merge(area: area, certid: input["certid"], comment: comment,
      secret_id: SecureRandom.uuid, created_by: identity.name))
    request.encrypted_private_key = CsrSecrets.encrypt(key, request, "key")
    request.encrypted_revoke_password = CsrSecrets.encrypt(SecureRandom.urlsafe_base64(32), request, "revoke")
    CertificateRequest.transaction do
      request.save!
      CsrAudit.record!("csr_create", request, identity, outcome: "succeeded")
    end
    request
  end

  def self.reveal(request, identity:, confirmed:)
    authorize!(identity, request.area)
    CsrNames.fail!(:confirmation) unless confirmed

    password = CsrSecrets.decrypt(request, "revoke")
    CsrAudit.record!("csr_reveal", request, identity, outcome: "succeeded")
    password
  rescue Certificates::Error
    CsrAudit.record!("csr_reveal", request, identity, outcome: "rejected") if identity.csr?(request.area)
    raise
  end
end
