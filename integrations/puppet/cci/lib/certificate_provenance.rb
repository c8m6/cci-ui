# frozen_string_literal: true

# Legacy source records can outlive the catalogue migration. Actor identities
# remain unchanged: an account name is not evidence of automated ownership.
module CertificateProvenance
  LEGACY_ACME_CLIENT = /(?:\A|[_.-])acme(?:[_.-]|\z)/i

  def self.obsolete_client?(client)
    client.is_a?(String) && LEGACY_ACME_CLIENT.match?(client)
  end

  def self.catalog_client(client)
    obsolete_client?(client) ? "puppet" : client
  end
end
