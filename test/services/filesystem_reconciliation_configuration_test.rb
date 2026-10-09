# frozen_string_literal: true

require "test_helper"

class FilesystemReconciliationConfigurationTest < ActiveSupport::TestCase
  test "defaults partial overrides and false are validated through environment JSON" do
    assert_equal({ "enabled" => true, "missing_after_scans" => 2, "max_delete_percent" => 20 },
      FilesystemReconciliationConfiguration.load_env({}))
    assert_equal({ "enabled" => false, "missing_after_scans" => 3, "max_delete_percent" => 10 },
      FilesystemReconciliationConfiguration.load_env("CCI_FILESYSTEM_RECONCILIATION" =>
        '{"enabled":false,"missing_after_scans":3,"max_delete_percent":10}'))
    assert_equal 0, FilesystemReconciliationConfiguration.load_env("CCI_FILESYSTEM_RECONCILIATION" =>
      '{"max_delete_percent":0}').fetch("max_delete_percent")
  end

  test "malformed unknown and unsafe settings fail without echoing their value" do
    ["", "secret-not-JSON", "null", "[]", '{"unknown":true}', '{"enabled":"true"}', '{"enabled":null}',
      '{"missing_after_scans":1}', '{"missing_after_scans":2.0}', '{"missing_after_scans":"2"}',
      '{"max_delete_percent":-1}', '{"max_delete_percent":101}', '{"max_delete_percent":20.5}'].each do |value|
      error = assert_raises(ArgumentError) do
        FilesystemReconciliationConfiguration.load_env("CCI_FILESYSTEM_RECONCILIATION" => value)
      end
      assert_includes error.message, "CCI_FILESYSTEM_RECONCILIATION"
      assert_not_includes error.message, "secret-not-JSON"
    end
  end
end
