# frozen_string_literal: true

require "test_helper"
require "open3"

class CertificateErrorTest < ActiveSupport::TestCase
  def standalone_error(setup = "")
    script = <<~RUBY
      require "json"
      #{setup}
      require "certificates/error"
      require "certificates/jks"
      before = defined?(I18n) && [I18n.locale, I18n.available_locales, I18n.enforce_available_locales]
      begin
        Certificates::Jks.load("", password: "")
      rescue Certificates::Error => error
        message = error.message
      end
      interpolated = Certificates::Error.translate("missing", default: "Area %{area}", area: "Zone A")
      after = defined?(I18n) && [I18n.locale, I18n.available_locales, I18n.enforce_available_locales]
      abort "I18n configuration changed" unless before == after
      puts JSON.generate(message: message, interpolated: interpolated)
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", Rails.root.join("lib").to_s, "-e", script)
    assert status.success?, error
    result = JSON.parse(output)
    assert_equal "Area Zone A", result.fetch("interpolated")
    result.fetch("message")
  end

  test "standalone errors work without I18n" do
    assert_equal "The JKS file is incomplete.", standalone_error
  end

  test "standalone errors work when I18n is loaded but has no locales" do
    assert_equal "The JKS file is incomplete.", standalone_error('require "i18n"')
  end

  test "standalone errors use translations when the locale is configured" do
    setup = <<~RUBY
      require "i18n"
      I18n.backend.store_translations(:en, errors: { app: { jks_incomplete: "The JKS file is incomplete." } })
      I18n.locale = :en
    RUBY
    assert_equal "The JKS file is incomplete.", standalone_error(setup)
  end
end
