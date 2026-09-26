# frozen_string_literal: true

# CSR audit records contain identifiers and fixed outcomes, never secret material.
class CsrAudit
  def self.record!(action, request, identity, **details)
    request.areas.each do |area|
      AuditEvent.create!(action: action, area: area, actor: identity.uid,
        actor_display_name: identity.display_name, references: [request.id.to_s],
        details: { csr_id: request.id, certid: request.certid, common_name: request.common_name,
                   target_areas: request.areas }.merge(details))
    end
  end
end
