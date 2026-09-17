require "test_helper"

class LocalizationTest < ActionDispatch::IntegrationTest
  def assert_language(locale)
    assert_response :success
    assert_equal locale, response.headers["Content-Language"]
    assert_select "html[lang=?]", locale
    refute_match(/translation_missing|Translation missing/, response.body)
    assert_equal :de, I18n.locale
  end

  test "sign in detects browser language and each request restores the default locale" do
    get login_path, headers: { "Accept-Language" => "fr,en-GB;q=0.9,de;q=0.5" }
    assert_language "en"
    assert_select "h2", text: "Local test sign-in"
    assert_select ".language-menu button[lang=en]", text: "English"
    assert_select ".language-menu button[lang=de]", text: "Deutsch"
    get login_path, headers: { "Accept-Language" => "de-AT,de;q=0.9" }
    assert_language "de"
    assert_select "h2", text: "Lokale Testanmeldung"
    get login_path, headers: { "Accept-Language" => "fr" }
    assert_language "de"
  end

  test "manual preference survives login logout and navigation and can return to browser detection" do
    post locale_path, params: { locale: "en", return_to: login_path }
    assert_redirected_to login_path
    get login_path, headers: { "Accept-Language" => "de" }
    assert_language "en"
    assert_select '.language-menu button[value=en][aria-pressed=true]'
    post local_login_path, params: { identity: "zone_a_writer" }
    get root_path, headers: { "Accept-Language" => "de" }
    assert_language "en"
    assert_select "h1", text: "Certificates"
    delete logout_path
    get login_path, headers: { "Accept-Language" => "de" }
    assert_language "en"
    post locale_path, params: { locale: "", return_to: login_path }
    get login_path, headers: { "Accept-Language" => "de" }
    assert_language "de"
    assert_select '.language-menu button[value=""][aria-pressed=true]'
    get login_path, headers: { "Accept-Language" => "en" }
    assert_language "en"
  end

  test "locale changes validate input reject external destinations and retain search filters" do
    post locale_path, params: { locale: "../../fr", return_to: root_path }
    assert_response :unprocessable_entity
    post locale_path, params: { locale: "en", return_to: "https://example.org" }
    assert_redirected_to root_path
    post locale_path, params: { locale: "de", return_to: "//example.org" }
    assert_redirected_to root_path
    post local_login_path, params: { identity: "zone_a_writer" }
    destination = certificates_path(q: "example", area: "zone_a", history: "1")
    get destination
    assert_select '.language-menu input[name=return_to][value=?]', destination
    post locale_path, params: { locale: "en", return_to: destination }
    assert_redirected_to destination
    follow_redirect!
    assert_language "en"
    assert_select 'input[name=q][value=example]'
  end

  test "English certificate details archive and PuppetDB presentation retain stored values" do
    cert, key = issue
    record = store(cert, key: key)
    record.update!(puppetdb_hosts: ["host.example.test"], puppetdb_checked_at: Time.current)
    previous = ENV["PUPPETDB_ENABLED"]
    ENV["PUPPETDB_ENABLED"] = "true"
    post locale_path, params: { locale: "en" }
    post local_login_path, params: { identity: "zone_a_keys" }
    get certificate_path(record)
    assert_language "en"
    assert_select "dt", text: "Created by"
    assert_select ".badge.success", text: "Valid"
    assert_select "#puppetdb-hosts p", text: "1 host reports this certificate."
    assert_select 'input[type=submit][value="Download certificate ↓"]'
    assert_includes response.body, cert.not_after.strftime("%Y-%m-%d")
    assert_includes response.body, "External client: test-client"
    assert_not_includes response.body, "PRIVATE KEY"
    get archive_certificate_path(record)
    assert_language "en"
    assert_select "h1", text: "Archive certificate?"
    assert_select "code", text: "delete"
    patch certificate_path(record), params: { rollout_status: "norollout", lookup_index: ConsulStore.status_snapshot(record).fetch(:index) }
    follow_redirect!
    assert_language "en"
    assert_select ".flash", text: "Puppet status saved."
    assert_equal "norollout", record.reload.rollout_status
    assert_equal "1", ConsulStore.get(record.area, record.source_id).fetch("schema")
  ensure
    ENV["PUPPETDB_ENABLED"] = previous
  end

  test "import preview switches language without recreating or consuming the draft" do
    post local_login_path, params: { identity: "zone_a_writer" }
    get new_import_path, headers: { "Accept-Language" => "en" }
    assert_language "en"
    assert_select "h1", text: "Import certificates"
    cert, = issue
    post imports_path, params: { areas: ["zone_a"], pem: cert.to_pem }, headers: { "Accept-Language" => "en" }
    assert_language "en"
    assert_select "h1", text: "Ready to save"
    token = css_select('input[name="token"]').first["value"]
    destination = css_select('.language-menu input[name="return_to"]').first["value"]
    assert_equal import_preview_path(token: token), destination
    assert_no_difference "ImportDraft.count" do
      post locale_path, params: { locale: "de", return_to: destination }
      follow_redirect!
      assert_language "de"
      assert_select "h1", text: "Bereit zum Speichern"
    end
    post imports_path, params: { token: token }
    follow_redirect!
    assert_select ".flash", text: "1 Zertifikat gespeichert."
    assert Certificate.exists?(fingerprint: Certificates::Codec.fingerprint(cert), source: "consul")
  end

  test "reopening previews still enforces session ownership" do
    post local_login_path, params: { identity: "zone_a_writer" }
    post imports_path, params: { areas: ["zone_a"], pem: issue.first.to_pem }
    token = css_select('input[name="token"]').first["value"]
    delete logout_path
    post local_login_path, params: { identity: "zone_a_writer" }
    preview_path = import_preview_path(token: token)
    get preview_path, headers: { "Accept-Language" => "en", "HTTP_REFERER" => "http://www.example.com#{preview_path}" }
    assert_redirected_to new_import_path
    assert_equal "The preview has expired or is not available for this session.", flash[:alert]
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Zertifikate importieren"
  end

  test "expired and consumed previews return to the import form without redirecting back" do
    post locale_path, params: { locale: "en" }
    post local_login_path, params: { identity: "zone_a_writer" }
    cert, = issue
    post imports_path, params: { areas: ["zone_a"], pem: cert.to_pem }
    token = css_select('input[name="token"]').first["value"]
    preview_path = import_preview_path(token: token)
    draft = ImportDraft.find_by!(token: token)

    [:expired, :consumed].each do |state|
      state == :expired ? draft.update!(expires_at: 1.minute.ago) : draft.destroy!
      [:get, :post].each do |method|
        assert_no_difference "Certificate.count" do
          headers = { "HTTP_REFERER" => "http://www.example.com#{preview_path}" }
          if method == :get
            get preview_path, headers: headers
          else
            post imports_path, params: { token: token }, headers: headers
          end
          assert_redirected_to new_import_path
          follow_redirect!
          assert_language "en"
          assert_select ".flash-error", text: "The preview has expired or is not available for this session."
          assert_select "h1", text: "Import certificates"
        end
      end
    end
  end

  test "a reader with an unavailable preview returns to the catalog" do
    post local_login_path, params: { identity: "zone_a_reader" }
    preview_path = import_preview_path(token: "0" * 48)
    get preview_path, headers: { "HTTP_REFERER" => "http://www.example.com#{preview_path}" }
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "store outage handlers retain the browser language and restore the locale" do
    record = store(issue.first)
    post local_login_path, params: { identity: "zone_a_reader" }
    original = ConsulStore.method(:status_snapshot)
    ConsulStore.define_singleton_method(:status_snapshot) { |_record| raise ConsulConnection::Error, "offline" }
    get certificate_path(record), headers: { "Accept-Language" => "en" }
    assert_response :service_unavailable
    assert_equal "en", response.headers["Content-Language"]
    assert_equal "The certificate store is currently unavailable. Please try again later.", response.body
    assert_equal :de, I18n.locale
  ensure
    ConsulStore.define_singleton_method(:status_snapshot, original) if original
  end

  test "English import errors and audit actions are translated" do
    post locale_path, params: { locale: "en" }
    post local_login_path, params: { identity: "zone_a_writer" }
    post imports_path, params: { areas: ["zone_a"], pem: "" }
    follow_redirect!
    assert_language "en"
    assert_select ".flash-error", text: "Please select files or enter PEM text."
    post imports_path, params: { areas: ["zone_a"], pem: "invalid-certificate" }
    assert_equal "PKCS#12 could not be read. Check the format, encryption and password.", flash[:alert]
    record = store(issue.first)
    ConsulStore.archive(record, actor: "test", expected_lookup_index: ConsulStore.status_snapshot(record).fetch(:index))
    CatalogIndexer.refresh_consul
    post local_login_path, params: { identity: "zone_a_auditor" }
    get audit_events_path
    assert_language "en"
    assert_select "h1", text: "Audit logs"
    assert_select 'option[value=archive]', text: "Certificate archived"
    assert_includes response.body, "Archiving confirmed: hidden from the overview"
    assert_includes response.body, "Import / new version"
    assert_select 'form input[type=hidden][name=return_to][value=?]', audit_events_path
  end
end
