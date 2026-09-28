# frozen_string_literal: true

require_relative "../../lib/certificate_diagnostics_configuration"

# Validation only: boot and web readiness never contact diagnostic providers.
CertificateDiagnosticsConfiguration.new
