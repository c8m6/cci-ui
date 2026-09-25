# frozen_string_literal: true

require "test_helper"
require "stringio"

class ErrorPagesTest < ActionDispatch::IntegrationTest
  setup do
    @original_details = Rails.application.config.x.show_error_details
    Rails.application.config.x.show_error_details = false
    @original_exceptions = Rails.application.env_config["action_dispatch.show_exceptions"]
    Rails.application.env_config["action_dispatch.show_exceptions"] = :all
    @log_output = StringIO.new
    @original_logger = Rails.logger
    @original_request_logger = Rails.application.env_config["action_dispatch.logger"]
    Rails.logger = ActiveSupport::Logger.new(@log_output)
    Rails.logger.formatter = ContainerLogFormatter.new
    OperationalLog.configure(Rails.logger)
    Rails.application.env_config["action_dispatch.logger"] = Rails.logger
  end

  teardown do
    Rails.application.config.x.show_error_details = @original_details
    Rails.application.env_config["action_dispatch.show_exceptions"] = @original_exceptions
    Rails.application.env_config["action_dispatch.logger"] = @original_request_logger
    Rails.logger = @original_logger
    OperationalLog.configure(@original_logger)
  end

  test "unknown routes render a localized anonymous page and log the error" do
    get "/missing-private-path", headers: { "Accept-Language" => "en-US", "X-Request-Id" => "error-page-test" }
    assert_error_page :not_found, "en", "Page not found"
    assert_select ".error-reference", text: /error-page-test/
    assert_select ".error-details", count: 0
    assert_not_includes response.body, "missing-private-path"
    assert_includes @log_output.string, "ActionController::RoutingError"
    assert_includes @log_output.string, "error-page-test"
    assert_select 'input[name=return_to][value="/"]'
  end

  test "Ruby errors are logged with details hidden and do not redirect to login" do
    post local_login_path, params: { identity: "zone_a_reader" }
    with_search_failure do
      get root_path, headers: { "Accept-Language" => "en" }
    end
    assert_error_page :internal_server_error, "en", "An internal error occurred"
    assert_select "nav", count: 1
    assert_select ".error-details", count: 0
    assert_not_includes response.body, "sensitive diagnostic"
    assert_not_includes response.body, "error_pages_test.rb"
    assert_includes @log_output.string, "NameError"
    assert_includes @log_output.string, "sensitive diagnostic"
    assert_includes @log_output.string, "error_pages_test.rb"
    assert_equal :de, I18n.locale
  end

  test "enabled diagnostics show escaped Ruby messages and stack traces and still log" do
    Rails.application.config.x.show_error_details = true
    post local_login_path, params: { identity: "zone_a_reader" }
    post locale_path, params: { locale: "en" }
    with_search_failure do
      get root_path, headers: { "Accept-Language" => "de-DE" }
    end
    assert_error_page :internal_server_error, "en", "An internal error occurred"
    assert_select ".error-details pre", text: /NameError/
    assert_select ".error-details pre", text: %r{sensitive diagnostic <script>alert\(1\)</script>}
    assert_select ".error-details pre", text: /error_pages_test.rb/
    assert_select ".error-details script", count: 0
    assert_includes @log_output.string, "sensitive diagnostic"
  end

  test "a database failure can render without querying the database again" do
    post local_login_path, params: { identity: "zone_a_reader" }
    original = Certificate.method(:visible_to)
    Certificate.define_singleton_method(:visible_to) { |_identity| raise ActiveRecord::ConnectionNotEstablished, "database offline" }
    get root_path, headers: { "Accept-Language" => "de-DE" }
    assert_error_page :service_unavailable, "de", "Dienst nicht verfügbar"
    assert_not_includes response.body, "database offline"
    assert_includes @log_output.string, "database offline"
  ensure
    Certificate.define_singleton_method(:visible_to, original) if original
  end

  test "invalid JSON and malformed queries render bad request pages without leaking input" do
    post local_login_path, params: '{"password":"private-value",'.dup,
      headers: { "Content-Type" => "application/json", "Accept-Language" => "en" }
    assert_error_page :bad_request, "en", "Invalid request"
    assert_not_includes response.body, "private-value"
    get "/login?identity[x]=a&identity[]=b", headers: { "Accept-Language" => "en" }
    assert_error_page :bad_request, "en", "Invalid request"
  end

  test "CSRF failures retain status and use the error layout" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post local_login_path, params: { identity: "zone_a_writer" }, headers: { "Accept-Language" => "en" }
    assert_error_page :unprocessable_content, "en", "The request could not be processed"
    assert_includes @log_output.string, "InvalidAuthenticityToken"
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "permission failures retain status and use the error layout" do
    post local_login_path, params: { identity: "zone_a_reader" }
    get new_import_path, headers: { "Accept-Language" => "en" }
    assert_error_page :forbidden, "en", "Access denied"
    assert_includes @log_output.string, '"http_status":403'
    assert_includes @log_output.string, '"state":"authorization_denied"'
    assert_includes @log_output.string, '"reason":"required_role_missing"'
  end

  test "a missing certificate stays a 404" do
    post local_login_path, params: { identity: "zone_a_reader" }
    get certificate_path(id: 0), headers: { "Accept-Language" => "en" }
    assert_error_page :not_found, "en", "Page not found"
    assert_not_includes response.body, "RecordNotFound"
    assert_includes @log_output.string, "ActiveRecord::RecordNotFound"
  end

  test "errors during Turbo frame searches request the complete error layout" do
    post local_login_path, params: { identity: "zone_a_reader" }
    with_search_failure do
      get root_path, headers: { "Accept-Language" => "en", "Turbo-Frame" => "results" }
    end
    assert_error_page :internal_server_error, "en", "An internal error occurred"
    assert_select 'meta[name="turbo-visit-control"][content="reload"]'
  end

  test "unsupported and invalid accept headers cannot break the error page" do
    ["application/json", "not a mime type"].each do |accept|
      get "/missing", headers: { "Accept" => accept, "Accept-Language" => "en" }
      assert_error_page :not_found, "en", "Page not found"
    end
  end

  test "HEAD errors preserve the status without a response body" do
    head "/missing", headers: { "Accept-Language" => "en" }
    assert_response :not_found
    assert_empty response.body
    assert_equal "en", response.headers["Content-Language"]
    assert_equal "text/html", response.media_type
    assert_includes @log_output.string, "ActionController::RoutingError"
  end

  test "HEAD Ruby errors log diagnostics without sending a body even when enabled" do
    Rails.application.config.x.show_error_details = true
    post local_login_path, params: { identity: "zone_a_reader" }
    with_search_failure { head root_path }
    assert_response :internal_server_error
    assert_empty response.body
    assert_includes @log_output.string, "sensitive diagnostic"
  end

  test "HEAD permission failures also have an empty body" do
    post local_login_path, params: { identity: "zone_a_reader" }
    head new_import_path
    assert_response :forbidden
    assert_empty response.body
    assert_includes @log_output.string, '"http_status":403'
  end

  private

  def with_search_failure
    original = CertificateSearch.method(:call)
    CertificateSearch.define_singleton_method(:call) do |*_args|
      raise NameError, "sensitive diagnostic <script>alert(1)</script>"
    end
    yield
  ensure
    CertificateSearch.define_singleton_method(:call, original)
  end

  def assert_error_page(status, locale, title)
    assert_response status
    assert_equal "text/html", response.media_type
    assert_equal locale, response.headers["Content-Language"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "html[lang=?]", locale
    assert_select ".sidebar .brand", text: "CCI-UI"
    assert_select ".language-menu", count: 1
    assert_select ".error-page h1", text: title
  end
end
