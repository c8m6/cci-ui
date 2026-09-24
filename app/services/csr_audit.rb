# frozen_string_literal: true

# CSR audit records contain identifiers and fixed outcomes, never secret material.
class CsrAudit
  def self.record!(action, request, identity, **details)
    AuditEvent.create!(action: action, area: request.area, actor: identity.name, references: [request.id.to_s],
      details: { csr_id: request.id, certid: request.certid, common_name: request.common_name }.merge(details))
  end
end
