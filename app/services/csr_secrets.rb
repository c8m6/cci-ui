# frozen_string_literal: true

# Keeps secret purpose and CSR identity in the authenticated encryption context.
class CsrSecrets
  FIELDS = { "key" => :encrypted_private_key, "revoke" => :encrypted_revoke_password }.freeze

  def self.encrypt(value, request, kind, encryption_key: nil)
    Certificates::Vault.encrypt(value, area: request.area, id: request.secret_context(kind), encryption_key: encryption_key)
  end

  def self.decrypt(request, kind, encryption_key: nil)
    Certificates::Vault.decrypt(request.public_send(FIELDS.fetch(kind)), area: request.area,
      id: request.secret_context(kind), encryption_key: encryption_key)
  rescue Certificates::Error, ArgumentError
    CsrNames.fail!(:decrypt)
  end
end
