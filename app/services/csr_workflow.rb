# frozen_string_literal: true

# Owns local CSR creation and disclosure independently of Consul availability.
class CsrWorkflow
  MAX_TARGET_AREAS = 21

  def self.authorize!(identity, areas)
    CsrNames.fail!(:forbidden) unless Array(areas).all? { |area| identity.csr?(area) }
  end

  def self.create(input, identity:)
    input = input.stringify_keys
    areas = CertificateAreaConfiguration.validate_selection!(input["areas"].presence || [input.fetch("area", "")])
    CsrNames.fail!(:target_count) if areas.size > MAX_TARGET_AREAS
    authorize!(identity, areas)
    ConsulStore.validate_certid!(input["certid"])
    areas.each { |area| Certificates::Vault.key(area) }
    comment = input.fetch("comment", "").to_s
    CsrNames.fail!(:subject) if comment.length > 2000

    material = CsrGeneration.new(input).generate
    key = material.delete(:private_key)
    request = CertificateRequest.new(material.merge(area: areas.first, target_areas: areas,
      certid: input["certid"], comment: comment, secret_id: SecureRandom.uuid, created_by: identity.uid))
    request.encrypted_private_key = CsrSecrets.encrypt(key, request, "key")
    request.encrypted_revoke_password = CsrSecrets.encrypt(SecureRandom.urlsafe_base64(32), request, "revoke")
    CertificateRequest.transaction do
      request.save!
      CsrAudit.record!("csr_create", request, identity, outcome: "succeeded")
    end
    request
  end

  def self.reveal(request, identity:, confirmed:)
    authorize!(identity, request.areas)
    CsrNames.fail!(:confirmation) unless confirmed

    password = CsrSecrets.decrypt(request, "revoke")
    CsrAudit.record!("csr_reveal", request, identity, outcome: "succeeded")
    password
  rescue Certificates::Error
    CsrAudit.record!("csr_reveal", request, identity, outcome: "rejected") if request.areas.all? { |area| identity.csr?(area) }
    raise
  end
end
