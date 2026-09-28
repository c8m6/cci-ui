# frozen_string_literal: true

module CertificateDiagnostics
  # Safe error codes never carry certificate-controlled URLs or response bodies.
  class Error < StandardError; end
end
