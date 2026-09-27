# frozen_string_literal: true

module CertificateDiagnostics
  # Explore alternate/cross-signed paths before classifying an incomplete chain.
  # Only vendor roots are anchors; inventory certificates are untrusted inputs.
  class TrustPaths
    MAX_PATHS = 256
    attr_reader :paths, :incomplete, :errors

    def initialize(certificate, candidates, roots, anchor_rules: {})
      @certificate = certificate
      @anchor_rules = anchor_rules
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
      rules = @anchor_rules.dig(fingerprint(path.last), "chrome")
      dated = rules && rules["enforce_anchor_expiry"] != [true] ? path[0...-1] : path
      dates_valid = dated.all? { |cert| cert.not_before <= Time.current && cert.not_after > Time.current }
      usage_valid = ignored_anchor_usage?(path, rules) || ca_usage_valid?
      if verify_store(path, rules) && usage_valid && dates_valid
        @paths << path
      else
        @errors << "invalid_path"
      end
    end

    def ignored_anchor_usage?(path, rules)
      path.size == 1 && rules && rules["enforce_anchor_constraints"] != [true]
    end

    def verify_store(path, rules)
      return true if path.size == 1 && rules

      store = OpenSSL::X509::Store.new
      store.add_cert(verification_anchor(path.last, rules))
      store.flags = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
      store.purpose = self.class.ca?(@certificate) ? OpenSSL::X509::PURPOSE_ANY : OpenSSL::X509::PURPOSE_SSL_SERVER
      store.time = Time.current
      store.verify(OpenSSL::X509::Certificate.new(@certificate.to_der),
        path[1...-1].map { |cert| OpenSSL::X509::Certificate.new(cert.to_der) })
    end

    def verification_anchor(anchor, rules)
      return anchor unless rules

      # OpenSSL consumes a certificate as its trust-anchor representation. Strip
      # only constraints Chrome explicitly does not enforce; retain subject, key,
      # issuer and serial so issuer/AKI matching still selects the exact anchor.
      copy = OpenSSL::X509::Certificate.new(anchor.to_der)
      unless rules["enforce_anchor_constraints"] == [true]
        factory = OpenSSL::X509::ExtensionFactory.new
        copy.extensions = [factory.create_extension("basicConstraints", "CA:TRUE", true)]
      end
      unless rules["enforce_anchor_expiry"] == [true]
        copy.not_before = Time.utc(1970)
        copy.not_after = Time.utc(9999)
      end
      OpenSSL::X509::Certificate.new(copy.to_der)
    end

    def ca_usage_valid?
      return true unless self.class.ca?(@certificate)

      usage = @certificate.extensions.find { |e| e.oid == "keyUsage" }
      !usage || usage.value.include?("Certificate Sign")
    end
  end
end
