const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const puppeteer = require(process.env.PUPPETEER_MODULE || 'puppeteer');

// Uses only synthetic requests in the disposable screenshot stack.
test('CSR form, isolated role and confirmed secret disclosure work in the browser', { timeout: 60000 }, async () => {
  const browser = await puppeteer.launch({
    headless: true,
    ...(process.env.PUPPETEER_EXECUTABLE_PATH ? { executablePath: process.env.PUPPETEER_EXECUTABLE_PATH } : {}),
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(10000);
    await page.setViewport({ width: 1440, height: 1100 });
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9' });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:3001/login', { waitUntil: 'networkidle0' });
    await page.select('#identity', 'zone_a_csr');
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle0' }),
      page.click('form[action="/local-login"] input[type=submit]'),
    ]);
    assert.equal(new URL(page.url()).pathname, '/certificate_requests');
    assert.equal(await page.$('nav a[href="/imports/new"]'), null);
    await page.goto('http://127.0.0.1:3001/certificate_requests/new', { waitUntil: 'networkidle0' });
    assert.equal(await page.$eval('#csr_key_size', el => el.value), '4096');
    assert.equal(await page.$eval('#csr_digest', el => el.value), 'SHA512');
    await page.type('#csr_certid', 'browser-demo');
    await page.type('#csr_common_name', 'portal.example.test');
    await page.type('#csr_sans', 'www.example.test\n192.0.2.7');
    await page.type('#csr_organization', 'Example Organization');
    await page.type('#csr_country', 'DE');
    await page.type('#csr_comment', 'Synthetic certificate request for documentation');
    if (process.env.CSR_SCREENSHOT === '1') {
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: path.resolve(__dirname, '../../docs/screenshots/csr-create.png'), fullPage: true });
    }
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle0' }),
      page.click('form[action="/certificate_requests"] input[type=submit]'),
    ]);
    const requestPath = new URL(page.url()).pathname;
    assert.match(requestPath, /^\/certificate_requests\/\d+$/);
    assert.equal(await page.$('[data-csr-secret-target]'), null);
    await page.click('input[name=confirm_reveal][type=checkbox]');
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle0' }),
      page.click('form[action$="/reveal"] input[type=submit]'),
    ]);
    const secret = await page.$eval('[data-csr-secret-target=value]', el => el.value);
    assert(secret.length >= 40);
    await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
    assert.equal(await page.$eval('[data-csr-secret-target=value]', el => el.value), '');
    assert.equal(await page.$eval('[data-csr-secret-target=value]', el => el.hasAttribute('value')), false);
    await page.goto('http://127.0.0.1:3001' + requestPath, { waitUntil: 'networkidle0' });
    assert(!(await page.content()).includes(secret));
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});
