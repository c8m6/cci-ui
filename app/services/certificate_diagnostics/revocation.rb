# frozen_string_literal: true

module CertificateDiagnostics
  # Strict freshness shared by both protocols; an interval never extends evidence.
  class Revocation
    def initialize(material, config, http:, area:)
      @material = material
      @cert = material.certificate
      @issuer = material.issuer
      @config = config
      @http = http
      @area = area
    end

    def call(check)
      return result("unknown", "not_applicable") if @material.self_signed?
      return result("unknown", "missing_issuer") unless @issuer

      public_send(check)
    rescue Error => e
      result("unknown", e.message)
    rescue OpenSSL::OpenSSLError, ArgumentError, TypeError, NoMethodError
      result("unknown", "malformed_evidence")
    end

    def ocsp
      url = @cert.ocsp_uris&.find { |value| value.match?(%r{\Ahttps?://}) }
      return result("unknown", "missing_url") unless url

      cert_id = OpenSSL::OCSP::CertificateId.new(@cert, @issuer, OpenSSL::Digest.new("SHA1"))
      request = OpenSSL::OCSP::Request.new.add_certid(cert_id)
      bytes = @http.fetch(url, body: request.to_der, content_type: "application/ocsp-request")
      response = OpenSSL::OCSP::Response.new(bytes)
      raise Error, "responder_error" unless response.status == OpenSSL::OCSP::RESPONSE_STATUS_SUCCESSFUL

      basic = response.basic
      store = OpenSSL::X509::Store.new
      store.add_cert(@issuer)
      store.flags = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
      raise Error, "invalid_signature" unless basic&.verify([@issuer], store, 0)

      single = basic.find_response(cert_id)
      raise Error, "wrong_certificate" unless single

      expiry = freshness(single.this_update, single.next_update)
      validate_produced_at(basic, single)

      state = { OpenSSL::OCSP::V_CERTSTATUS_GOOD => "good", OpenSSL::OCSP::V_CERTSTATUS_REVOKED => "revoked" }
              .fetch(single.cert_status, "unknown")
      result(state, state == "unknown" ? "responder_unknown" : state, expires_at: expiry,
        details: { issuer: Certificates::Codec.fingerprint(@issuer), this_update: single.this_update.iso8601 })
    end

    def crl
      urls = distribution_points
      return result("unknown", "missing_url") if urls.empty?

      failures = []
      urls.each do |url|
        outcome = verify_crl(cached_crl(url))
        return outcome
      rescue Error => e
        failures << e.message
      end
      result("unknown", failures.first || "missing_url")
    end

    private

    def validate_produced_at(basic, single)
      # producedAt is signed and must not postdate now or predate thisUpdate.
      produced = OpenSSL::ASN1.decode(basic.to_der).value.first.value.find { |node| node.is_a?(OpenSSL::ASN1::GeneralizedTime) }&.value
      raise Error, "invalid_time" unless produced && produced <= Time.current + @config[:clock_skew] &&
                                         produced >= single.this_update - @config[:clock_skew]
    end

    def result(state, reason, expires_at: nil, details: {})
      { state: state, reason: reason, expires_at: expires_at, details: details, data_version: "revocation-v1" }
    end

    def freshness(this_update, next_update)
      now = Time.current
      raise Error, "invalid_time" unless this_update && this_update <= now + @config[:clock_skew]

      expiry = [next_update || (this_update + @config[:evidence_max_age]), this_update + @config[:evidence_max_age]].min
      raise Error, "expired_evidence" if expiry <= now || expiry <= this_update

      expiry
    end

    def extension_der(extension)
      OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(extension.to_der).value.last.value)
    end

    def distribution_points
      extension = @cert.extensions.find { |entry| entry.oid == "crlDistributionPoints" }
      return [] unless extension

      extension_der(extension).value.flat_map do |point|
        # Only direct, complete, fullName URI DPs. Reject reason masks and cRLIssuer.
        raise Error, "unsupported_crl_scope" unless point.value.size == 1 && point.value.first.tag.zero?

        name = point.value.first.value.first
        raise Error, "unsupported_crl_scope" unless name.tag.zero?

        name.value.filter_map do |entry|
          entry.value if entry.tag == 6 && entry.value.match?(%r{\Ahttps?://})
        end
      end
    end

    def cached_crl(url)
      key = Digest::SHA256.hexdigest([@area, Certificates::Codec.fingerprint(@issuer), url].join("\0"))
      cache = CertificateDiagnosticCache.find_by(cache_id: "crl:#{key}")
      return OpenSSL::X509::CRL.new(cache.payload) if cache&.expires_at && cache.expires_at > Time.current

      crl = OpenSSL::X509::CRL.new(@http.fetch(url))
      checked = verify_crl(crl)
      CertificateDiagnosticCache.find_or_initialize_by(cache_id: "crl:#{key}").update!(payload: crl.to_der,
        expires_at: checked.fetch(:expires_at))
      crl
    end

    def validate_crl_scope(crl)
      unsupported = %w[deltaCRL deltaCRLIndicator issuingDistributionPoint freshestCRL]
      raise Error, "unsupported_crl_scope" if crl.extensions.any? do |ext|
        unsupported.include?(ext.oid) || (ext.critical? && !%w[authorityKeyIdentifier crlNumber].include?(ext.oid))
      end
      raise Error, "unsupported_crl_scope" if crl.revoked.any? do |entry|
        entry.extensions.any? { |ext| ext.oid == "certificateIssuer" || ext.critical? || ext.value == "Remove From CRL" }
      end
    end

    def verify_crl(crl)
      validate_crl_scope(crl)
      usage = @issuer.extensions.find { |ext| ext.oid == "keyUsage" }
      raise Error, "invalid_signature" if usage && !usage.value.include?("CRL Sign")
      raise Error, "invalid_signature" unless crl.issuer == @issuer.subject && crl.verify(@issuer.public_key)

      expiry = freshness(crl.last_update, crl.next_update)
      revoked = crl.revoked.find { |entry| entry.serial == @cert.serial }
      raise Error, "invalid_time" if revoked && revoked.time > Time.current + @config[:clock_skew]

      state = revoked ? "revoked" : "good"
      result(state, state, expires_at: expiry, details: { issuer: Certificates::Codec.fingerprint(@issuer),
                                                          this_update: crl.last_update.iso8601 })
    end
  end
end
