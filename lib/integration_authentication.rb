# frozen_string_literal: true

require "digest"

# Header-only authentication for stateless, deployment-configured integrations.
module IntegrationAuthentication
  def self.valid_bearer?(header, expected)
    match = %r{\ABearer ([A-Za-z0-9\-._~+/]+=*)\z}i.match(header.to_s)
    return false unless match && expected.present?

    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.digest(match[1]), Digest::SHA256.digest(expected))
  end
end
