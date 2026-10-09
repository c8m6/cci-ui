# frozen_string_literal: true

# Validated process configuration for the filesystem catalog's cleanup phase.
class FilesystemReconciliationConfiguration
  DEFAULTS = { "enabled" => true, "missing_after_scans" => 2, "max_delete_percent" => 20 }.freeze

  def self.load_env(environment = ENV)
    supplied = AreaConfiguration.parse_object(environment.fetch("CCI_FILESYSTEM_RECONCILIATION", "{}"),
      "CCI_FILESYSTEM_RECONCILIATION")
    settings = DEFAULTS.merge(supplied)
    unless (supplied.keys - DEFAULTS.keys).empty? && [true, false].include?(settings["enabled"]) &&
           settings["missing_after_scans"].is_a?(Integer) && settings["missing_after_scans"] >= 2 &&
           settings["max_delete_percent"].is_a?(Integer) && settings["max_delete_percent"].between?(0, 100)
      raise ArgumentError, "CCI_FILESYSTEM_RECONCILIATION requires enabled (boolean), missing_after_scans (integer >= 2) " \
                           "and max_delete_percent (integer 0..100); unknown keys are rejected."
    end

    settings.freeze
  end

  def self.configuration = @configuration ||= load_env
end
