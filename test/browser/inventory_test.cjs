const { test } = require('node:test');
const assert = require('node:assert/strict');
const puppeteer = require(process.env.PUPPETEER_MODULE || 'puppeteer');

// Run against the disposable, synthetically seeded screenshot stack.
test('host navigation, real identity, complete clipboard values and neutral status controls', { timeout: 90000 }, async () => {
  const browser = await puppeteer.launch({
    headless: true,
    ...(process.env.PUPPETEER_EXECUTABLE_PATH ? { executablePath: process.env.PUPPETEER_EXECUTABLE_PATH } : {}),
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(10000);
    await browser.defaultBrowserContext().overridePermissions('http://127.0.0.1:3001', ['clipboard-read', 'clipboard-sanitized-write']);
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9' });
    await page.goto('http://127.0.0.1:3001/login', { waitUntil: 'networkidle0' });
    await page.select('#identity', 'all:writer');
    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle0' }), page.click('input[type=submit]')]);
    await page.goto('http://127.0.0.1:3001/certificates?sort=name', { waitUntil: 'networkidle0' });
    const portal = await page.$$eval('a.certificate-name', nodes => nodes.find(node => node.textContent === 'portal.example.test').href);
    await page.goto(portal, { waitUntil: 'networkidle0' });
    assert.equal(await page.$eval('.status-form .management-note', node => node.classList.contains('flash-error')), false);
    const identity = await page.$eval('pre', node => node.textContent);
    assert(identity.includes('certid: portal.production'));
    assert(identity.includes('area: zone_a'));
    assert(!identity.includes('lookup:'));
    const checkFingerprints = async () => {
      const values = await page.$$eval('.fingerprint-value', nodes => nodes.map(node => node.textContent));
      assert(values.length > 0);
      assert(values.every(value => /^[0-9a-f]{64}$/.test(value)));
      await page.bringToFront();
      await page.click('.fingerprint-copy');
      await page.waitForFunction(() => document.querySelector('.fingerprint [role=status]').textContent.length > 0);
      assert.equal(await page.$eval('.fingerprint [role=status]', node => node.textContent), 'Copied');
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), values[0]);
      for (const width of [1440, 600, 390, 320]) {
        await page.setViewport({ width, height: 1100 });
        const fits = await page.$$eval('.fingerprint-value', nodes => nodes.every(node => {
          const style = getComputedStyle(node);
          return node.scrollWidth <= node.clientWidth + 1 && style.textOverflow !== 'ellipsis' && style.overflow === 'visible';
        }));
        assert(fits, 'Full fingerprint must wrap at ' + width);
      }
    };
    await checkFingerprints();
    await page.setViewport({ width: 1440, height: 1100 });
    await page.goto(await page.$eval('nav a[href="/hosts"]', node => node.href), { waitUntil: 'networkidle0' });
    assert((await page.$eval('.host-table td:first-child', node => node.clientWidth)) > 240, 'Hostname column must not inherit checkbox width');
    await page.goto(await page.$eval('tbody a', node => node.href), { waitUntil: 'networkidle0' });
    await page.waitForSelector('.host-certificate');
    await checkFingerprints();
    assert((await page.$eval('h1', node => node.textContent)).endsWith('.example.test'));
  } finally {
    await browser.close();
  }
});
