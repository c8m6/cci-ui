# frozen_string_literal: true

module CertificateDiagnostics
  # Explore alternate/cross-signed paths before classifying an incomplete chain.
  # Only vendor roots are anchors; inventory certificates are untrusted inputs.
  class TrustPaths
    MAX_PATHS = 256
    attr_reader :paths, :incomplete, :errors

    def initialize(certificate, candidates, roots)
      @certificate = certificate
      @roots = roots
      @pool = (candidates + roots).uniq { |cert| fingerprint(cert) }
      @anchor_ids = roots.map { |cert| fingerprint(cert) }
      @paths = []
      @errors = []
      @incomplete = false
      @visited = 0
      walk([certificate])
    end

    def self.ca?(cert)
      cert.extensions.any? { |e| e.oid == "basicConstraints" && e.value.include?("CA:TRUE") }
    end

    private

    def fingerprint(cert) = Certificates::Codec.fingerprint(cert)

    def self_signed?(cert) = cert.subject == cert.issuer && cert.verify(cert.public_key)

    def walk(path)
      @visited += 1
      if path.size > CciClient::MAX_CHAIN_ISSUERS + 1 || @visited > MAX_PATHS
        @incomplete = true
        return
      end
      current = path.last
      if @anchor_ids.include?(fingerprint(current))
        verify(path)
        return
      end
      if self_signed?(current)
        @errors << "private_root"
        return
      end
      parents = @pool.select do |candidate|
        candidate.subject == current.issuer && path.none? do |c|
          fingerprint(c) == fingerprint(candidate)
        end
      end
      @incomplete = true if parents.empty?
      parents.each do |parent|
        if current.verify(parent.public_key)
          walk(path + [parent])
        else
          @errors << "invalid_path"
        end
      end
    end

    def verify(path)
      store = OpenSSL::X509::Store.new
      store.add_cert(path.last)
      store.flags = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
      store.purpose = self.class.ca?(@certificate) ? OpenSSL::X509::PURPOSE_ANY : OpenSSL::X509::PURPOSE_SSL_SERVER
      store.time = Time.current
      valid = store.verify(OpenSSL::X509::Certificate.new(@certificate.to_der),
        path[1...-1].map { |cert| OpenSSL::X509::Certificate.new(cert.to_der) })
      if valid && ca_usage_valid? && path.all? { |cert| cert.not_before <= Time.current && cert.not_after > Time.current }
        @paths << path
      else
        @errors << "invalid_path"
      end
    end

    def ca_usage_valid?
      return true unless self.class.ca?(@certificate)

      usage = @certificate.extensions.find { |e| e.oid == "keyUsage" }
      !usage || usage.value.include?("Certificate Sign")
    end
  end
end
