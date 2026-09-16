// Capture real application pages; do not alter their DOM or styles for images.
const assert = require('node:assert/strict');
const path = require('node:path');
const puppeteer = require(process.env.PUPPETEER_MODULE || 'puppeteer');

(async () => {
  const browser = await puppeteer.launch({
    headless: true,
    ...(process.env.PUPPETEER_EXECUTABLE_PATH ? { executablePath: process.env.PUPPETEER_EXECUTABLE_PATH } : {}),
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1800, height: 1100, deviceScaleFactor: 1 });
    await page.emulateTimezone('Europe/Berlin');
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
    const base = 'http://127.0.0.1:3001';
    const output = path.resolve(__dirname, '../../docs/screenshots');
    const ready = async () => {
      await page.evaluate(() => document.fonts.ready);
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.theme));
    };
    const capture = async filename => {
      await page.setViewport({ width: 1800, height: 1100, deviceScaleFactor: 1 });
      const height = await page.evaluate(() => document.documentElement.scrollHeight);
      // A page-height viewport keeps the fixed sidebar intact in the capture.
      await page.setViewport({ width: 1800, height, deviceScaleFactor: 1 });
      await page.screenshot({ path: path.join(output, filename), fullPage: true });
    };
    const login = async identity => {
      await page.goto(`${base}/anmelden`, { waitUntil: 'networkidle0' });
      await page.select('#identity', identity);
      await page.click('input[type=submit]');
      await page.waitForFunction(() => !location.pathname.includes('anmelden'));
      await ready();
    };
    await login('all:keys');
    await page.goto(`${base}/zertifikate?sort=name`, { waitUntil: 'networkidle0' });
    await ready();
    const headers = await page.$$eval('thead th', cells => cells.map(cell => cell.textContent.trim()));
    assert(headers.includes('Hosts'));
    assert(headers.includes('Puppet-Status'));
    const portal = await page.$eval('a.certificate-name', () => {
      const link = [...document.querySelectorAll('a.certificate-name')].find(a => a.textContent === 'portal.example.test');
      return { url: link.href, hosts: link.closest('tr').querySelector('.puppetdb-host-count').textContent.trim() };
    });
    assert.equal(portal.hosts, '3');
    assert.equal(await page.$$eval('tbody tr', rows => rows.length), 6);
    await capture('overview.png');

    await page.goto(portal.url, { waitUntil: 'networkidle0' });
    await page.click('.theme-toggle');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'slate');
    await ready();
    const hosts = await page.$$eval('#puppetdb-hosts li', nodes => nodes.map(node => node.textContent));
    assert.deepEqual(hosts, ['proxy01.example.test', 'web01.example.test', 'web02.example.test']);
    assert.equal(await page.$eval('.status-actions input[type=submit]', node => node.value), 'Status speichern');
    assert.equal(await page.$eval('.status-actions a', node => node.textContent), 'Archivieren');
    await capture('details.png');

    await page.click('.account input[type=submit], .account button.text-button');
    await page.waitForFunction(() => location.pathname === '/anmelden');
    await login('all:auditor');
    await page.goto(`${base}/auditlogs`, { waitUntil: 'networkidle0' });
    await page.click('.theme-toggle');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'default');
    await ready();
    // The top rows include the newest archive/status/export events.
    const audit = await page.$eval('.audit-table', node => node.textContent);
    assert(audit.includes('Zertifikat archiviert'));
    assert(audit.includes('Puppet-Status geändert'));
    assert(audit.includes('Zertifikate exportiert'));
    await capture('audit.png');
    assert.deepEqual(errors, []);
    console.log('Updated overview.png, details.png and audit.png; host counts, names and controls verified.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
