# Fail at boot on invalid configuration instead of starting with partial access.
require_relative "../../lib/area_configuration"
AreaConfiguration.configuration
