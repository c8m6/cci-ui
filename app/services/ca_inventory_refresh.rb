# frozen_string_literal: true

# Resolves local issuer relationships without fetching URLs or loading private keys.
class CaInventoryRefresh
  def self.run
    return unless CaInventory.enabled?

    now = Time.current
    snapshots = AreaConfiguration.ids.to_h { |area| [area, new(area).snapshot] }
    CaInventory.transaction do
      snapshots.each do |area, snapshot|
        CaInventory.find_or_initialize_by(area: area).update!(**snapshot, checked_at: now, error_at: nil)
      end
    end
  rescue Certificates::Error, ConsulConnection::Error, OpenSSL::OpenSSLError
    failed!
    raise
  end

  def self.failed!
    return unless CaInventory.enabled?

    AreaConfiguration.ids.each do |area|
      CaInventory.find_or_initialize_by(area: area).update!(error_at: Time.current)
    end
  end

  def initialize(area)
    @area = area
    @issues = {}
    @parents = {}
  end

  def snapshot
    # Prefer filesystem references to preserve the .tag suffix used by Puppet.
    @entries = Certificate.retained.where(area: @area).order(source: :desc, active: :desc, id: :asc).map do |record|
      [record, CertificateMaterial.load(record).fetch(:certificate)]
    end
    @entries.uniq! { |record, _cert| record.fingerprint }
    candidates = @entries.select { |_record, cert| usable_ca?(cert) }
    @candidates = candidates.group_by { |_record, cert| cert.subject.hash }
    @entries.each { |entry| walk(entry, []) }
    authorities = candidates.map { |entry| authority(*entry) }
    { authorities: authorities.sort_by { |entry| [entry.fetch(:subject), entry.fetch(:fingerprint)] }, issues: @issues.values }
  end

  private

  def usable_ca?(cert)
    constraints = cert.extensions.find { |extension| extension.oid == "basicConstraints" }
    usage = cert.extensions.find { |extension| extension.oid == "keyUsage" }
    constraints&.value&.include?("CA:TRUE") && (!usage || usage.value.include?("Certificate Sign"))
  end

  def referenceable_ca?(record, cert)
    usable_ca?(cert) && (record.source == "filesystem" || record.active)
  end

  def root?(cert)
    cert.subject == cert.issuer && cert.verify(cert.public_key)
  end

  def parents(record, cert)
    @parents[record.fingerprint] ||= @candidates.fetch(cert.issuer.hash, []).select do |_candidate_record, candidate|
      cert.issuer == candidate.subject && cert.verify(candidate.public_key)
    end
  end

  def walk(entry, path)
    record, cert = entry
    return if root?(cert) && usable_ca?(cert)
    return issue(record, "cycle") if path.include?(record.fingerprint)
    return issue(record, "depth") if path.length >= CciClient::MAX_CHAIN_ISSUERS

    issuers = parents(record, cert)
    return issue(record, "missing") if issuers.empty?

    issuers.each { |parent| walk(parent, [*path, record.fingerprint]) }
  end

  def issue(record, reason)
    @issues[[record.fingerprint, reason]] = { certificate_id: record.id, subject: record.subject,
                                            not_before: record.not_before.iso8601, not_after: record.not_after.iso8601,
                                            issuer: record.issuer, reason: reason }
  end

  def authority(record, cert)
    { certificate_id: record.id, subject: record.subject, fingerprint: record.fingerprint,
      referenceable: referenceable_ca?(record, cert),
      not_before: cert.not_before.iso8601, not_after: cert.not_after.iso8601,
      issuer_fingerprints: root?(cert) ? [] : parents(record, cert).map { |parent, _certificate| parent.fingerprint }.sort,
      kind: root?(cert) ? "root" : "intermediate", hiera: HieraSnippet.reference(record, cert) }
  end
end
