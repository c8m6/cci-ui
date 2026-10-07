# frozen_string_literal: true

# Resolves automatic CA names against live Consul data and other entries in a bundle.
# Existing issuers are reused without changing their versions, status or provenance.
class IssuerImport
  def initialize(area)
    @area = area
    @reserved = {}
  end

  def resolve(cert)
    names = [Certificates::Codec.issuer_certid(cert), Certificates::Codec.issuer_certid_alternative(cert)]
    candidates = names.map { |name| candidate(name) }
    matching = candidates.find { |item| item[:der] == cert.to_der }
    return matching.slice(:certid, :snapshot, :reuse_version) if matching

    available = candidates.find { |item| !item[:snapshot] && !@reserved.key?(item[:certid]) }
    raise Certificates::Error, I18n.t("errors.app.issuer_collision", certid: names.first) unless available

    @reserved[available.fetch(:certid)] = true
    available.slice(:certid, :snapshot)
  end

  def candidate(name)
    snapshot = ConsulStore.certid_snapshot(@area, name)
    return { certid: name, snapshot: nil } unless snapshot

    meta = JSON.parse(snapshot.fetch(:value))
    version = meta.fetch("active_version")
    material = ConsulStore.get(@area, "#{name}/#{version}")
    cert = OpenSSL::X509::Certificate.new(material.fetch("pem"))
    { certid: name, snapshot: snapshot, reuse_version: version, der: cert.to_der }
  end

  def self.reuse(entry, cert)
    snapshot = ConsulStore.certid_snapshot(entry.fetch("area"), entry.fetch("certid"))
    id = "#{entry.fetch("certid")}/#{entry.fetch("reuse_version")}"
    unless snapshot && snapshot.fetch(:index) == entry.fetch("certid_index") &&
           OpenSSL::X509::Certificate.new(ConsulStore.get(entry.fetch("area"), id).fetch("pem")).to_der == cert.to_der
      raise Certificates::Error, I18n.t("errors.app.preview_changed")
    end

    id
  end
end
