# frozen_string_literal: true

module CertificateDiagnostics
  # Metadata-only dependency identities include every reachable issuer candidate,
  # including missing-issuer lookups and alternate paths, within the current area.
  class Inventory
    def initialize(area)
      @certificates = Certificate.retained.where(area: area).distinct.pluck(:fingerprint, :subject, :issuer)
      @subjects = @certificates.group_by { |_, subject, _| subject }
      @issuers = @certificates.to_h { |fingerprint, _, issuer| [fingerprint, issuer] }
    end

    def versions
      @issuers.to_h { |fingerprint, _| [fingerprint, version(fingerprint)] }
    end

    def version(fingerprint)
      seen = { fingerprint => true }
      frontier = [@issuers.fetch(fingerprint)]
      CciClient::MAX_CHAIN_ISSUERS.times do
        parents = frontier.uniq.flat_map { |subject| @subjects.fetch(subject, []) }
                          .reject { |parent, _, _| seen[parent] }
        break if parents.empty?

        parents.each { |parent, _, _| seen[parent] = true }
        frontier = parents.map(&:last)
      end
      Digest::SHA256.hexdigest(seen.keys.sort.join)
    end
  end
end
