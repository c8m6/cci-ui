# frozen_string_literal: true

require "test_helper"

class ApplicationBuildTest < ActiveSupport::TestCase
  test "build information uses development fallbacks for missing and blank values" do
    with_build_environment("APP_VERSION" => nil, "APP_REVISION" => " ", "APP_BUILD_TIME" => nil) do
      assert_equal({ version: "development", revision: "unknown", build_time: "unknown" }, ApplicationBuild.to_h)
    end
  end

  test "build information comes from the container environment" do
    with_build_environment("APP_VERSION" => "v1.4.2", "APP_REVISION" => "a3f928c",
      "APP_BUILD_TIME" => "2026-09-26T08:35:21Z") do
      assert_equal "v1.4.2", ApplicationBuild.version
      assert_equal "a3f928c", ApplicationBuild.revision
      assert_equal "2026-09-26T08:35:21Z", ApplicationBuild.build_time
    end
  end

  private

  def with_build_environment(values)
    previous = values.to_h { |name, _| [name, ENV.fetch(name, nil)] }
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
