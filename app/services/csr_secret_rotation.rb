# frozen_string_literal: true

# Offline maintenance step. Consul material must be rotated separately before resuming writers.
class CsrSecretRotation
  def self.call(area:, old_key:, new_key:, actor:)
    raise ArgumentError, "Unknown area" unless AreaConfiguration.ids.include?(area)
    raise ArgumentError, "An audit actor is required" if actor.blank?

    raise ArgumentError, "Explicit rotation keys are required" unless old_key.is_a?(String) && new_key.is_a?(String)

    Certificates::Vault.encryption_key(area, old_key)
    Certificates::Vault.encryption_key(area, new_key)
    CatalogIndexer.synchronize do
      CertificateRequest.transaction do
        requests = CertificateRequest.where(area: area)
        unresolved = CsrCertificate.where(certificate_request_id: requests.select(:id)).where.not(state: "published")
        raise Certificates::Error, "Resolve pending publication intents before rotating" if unresolved.where.not(prepared: {}).exists?

        requests.find_each do |request|
          attributes = CsrSecrets::FIELDS.to_h do |kind, field|
            plaintext = CsrSecrets.decrypt(request, kind, encryption_key: old_key)
            [field, CsrSecrets.encrypt(plaintext, request, kind, encryption_key: new_key)]
          end
          # Completed intents also contain encrypted Consul material. They are no longer needed for retries.
          request.csr_certificates.where(state: "published").update_all(prepared: {})
          request.update!(attributes)
          AuditEvent.create!(action: "csr_rotate", area: area, actor: actor, references: [request.id.to_s],
            details: { csr_id: request.id, outcome: "succeeded" })
        end
        requests.count
      end
    end
  end
end
