const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const puppeteer = require(process.env.PUPPETEER_MODULE || 'puppeteer');

// Run against the disposable screenshot stack, not a production inventory.
test('language switching retains live search filters and POST-rendered previews', { timeout: 60000 }, async () => {
  const browser = await puppeteer.launch({
    headless: true,
    protocolTimeout: 15000,
    ...(process.env.PUPPETEER_EXECUTABLE_PATH ? { executablePath: process.env.PUPPETEER_EXECUTABLE_PATH } : {}),
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(10000);
    page.setDefaultNavigationTimeout(15000);
    await page.setViewport({ width: 1440, height: 1000 });
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9' });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:3001/anmelden', { waitUntil: 'networkidle0' });
    await page.select('#identity', 'zone_a_writer');
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle0' }),
      page.click('form[action="/lokale-anmeldung"] input[type=submit]'),
    ]);

    // Exercise the real debounced Turbo search rather than navigating to a
    // prebuilt URL, which would also refresh the language form on the server.
    await page.type('input[name=q]', 'locale-browser-no-match');
    await page.waitForFunction(() => location.search.includes('locale-browser-no-match') && !document.querySelector('#results').hasAttribute('busy'));
    await page.select('select[name=source]', 'consul');
    await page.waitForFunction(() => new URL(location.href).searchParams.get('source') === 'consul' && !document.querySelector('#results').hasAttribute('busy'));
    const search = new URL(page.url()).search;
    const switchLanguage = async locale => {
      await page.click('.language-menu summary');
      await Promise.all([
        page.waitForNavigation({ waitUntil: 'networkidle0' }),
        page.click(`.language-menu button[value="${locale}"]`),
      ]);
      assert.equal(await page.$eval('html', node => node.lang), locale);
    };
    await switchLanguage('de');
    assert.equal(new URL(page.url()).search, search);
    assert.equal(await page.$eval('input[name=q]', node => node.value), 'locale-browser-no-match');
    assert.equal(await page.$eval('select[name=source]', node => node.value), 'consul');

    await page.click('nav a[href="/import/new"]');
    await page.waitForSelector('textarea[name=pem]');
    await page.click('form[action="/import"] details summary');
    const pem = execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', '/dev/null', '-subj', '/CN=locale-browser.example.test', '-days', '1'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000 });
    await page.type('textarea[name=pem]', pem);
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle0' }),
      page.click('form[action="/import"] input[type=submit]'),
    ]);
    assert.equal(new URL(page.url()).pathname, '/import');
    const token = await page.$eval('input[name=token]', node => node.value);
    await switchLanguage('en');
    assert.equal(new URL(page.url()).pathname, '/import/vorschau');
    assert.equal(new URL(page.url()).searchParams.get('token'), token);
    assert.equal(await page.$eval('input[name=token]', node => node.value), token);
    assert.equal(await page.$eval('h1', node => node.textContent), 'Ready to save');
    assert.deepEqual(errors, []);
    // Do not commit the preview. Disposing of the demo stack removes the draft.
  } finally {
    await browser.close();
  }
});
