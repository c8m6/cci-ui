# Interface languages

CCI-UI supports German and English. The language menu in the upper-right corner
is available on the sign-in screen and throughout the workspace. It displays
the current language code and lists languages by their native names.

The application chooses the language in this order:

1. A language explicitly selected in the menu, stored in a signed browser cookie.
2. The best supported language from the browser's `Accept-Language` header,
   taking quality weights into account. Regional preferences such as `en-GB`
   and `de-DE` also match their base language.
3. German when no supported preference is available.

Choose **Browsersprache** / **Browser language** to clear the manual preference.
The cookie is independent of the login session, so the preference survives sign-in
and sign-out. It applies to this browser, rather than to the user's account.
Language changes retain the current page and search filters. An existing import
preview can be reopened in the selected language without processing the upload
again. It retains its original session ownership and 15-minute expiry. Unsaved
form input is not retained across a language change.

Interface labels, confirmation messages, application errors, dates, number
formatting and dynamic selection counts are localized. Certificate contents,
tags, configured area labels, user identities, certids, stored status values
(`active`, `norollout`, `delete`) and Consul's storage contract are unchanged.
External audit comments remain as supplied. The application's fixed archive
message is translated for display without rewriting the audit record. Operational
logs and standalone integration client diagnostics are not browser-localized.

## Adding a language

1. Copy `config/locales/en.yml` to `config/locales/<locale>.yml`, for example
   `fr.yml`, and change the top-level key to the same locale code.
2. Translate the values, including `language_name` in the language's own spelling.
   Retain the translation keys and `%{variable}` placeholders. Adjust date, time,
   number and sentence-list formats for the language.
3. Supply the appropriate plural forms for count messages. German and English
   use `one` and `other`. A language with additional plural categories also needs
   an I18n backend pluralization rule. JavaScript selection counts use the browser's
   `Intl.PluralRules` and the same translated forms.
4. Run the localization tests and the full application suite, then rebuild and
   restart the application. Available languages are discovered from these YAML
   filenames at boot. The language menu uses that list automatically, so no view
   or language-detection code needs to be changed.

Keep one complete catalog per locale. Language selection uses
`I18n.with_locale` for each request so it does not affect other requests or
background indexing. New interface text belongs in the catalogs, including
accessible labels and client-side messages. Pass translations to Stimulus through
data attributes. Use `t` in views, `I18n.t` in application code and `l` for dates.
Keep status keys and other machine-readable values independent of translated labels.

Translation keys ending in `_html` may contain reviewed static markup. Pass
dynamic values through the view's `t` helper so interpolation remains escaped.
Never mark user-supplied values as HTML-safe to translate them.

```bash
docker compose -f compose.yml exec -T web ruby bin/rails test \
  test/services/browser_locale_test.rb test/integration/localization_test.rb
docker compose -f compose.yml exec -T web ruby bin/rails test
docker compose -f compose.yml up --build -d --wait
```

The browser regression test exercises live Turbo search followed by a language
change, and switching an existing POST-rendered import preview. Run it against
the disposable screenshot stack with Node.js, OpenSSL and Puppeteer installed:

```bash
docker compose -f script/screenshots/compose.yml up --build -d --wait
PUPPETEER_MODULE=/path/to/node_modules/puppeteer node --test test/browser/localization_test.cjs
docker compose -f script/screenshots/compose.yml down
```

`PUPPETEER_EXECUTABLE_PATH` can select a compatible Chrome binary. The test
creates an uncommitted synthetic preview. Removing the demo stack discards it.
