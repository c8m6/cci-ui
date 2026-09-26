# frozen_string_literal: true

# Fail at boot on invalid configuration instead of starting with partial access.
require_relative "../../lib/area_configuration"
require_relative "../../lib/certificate_area_configuration"
AreaConfiguration.configuration
CertificateAreaConfiguration.mode
