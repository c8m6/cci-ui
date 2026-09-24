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
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9' });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
    const base = 'http://127.0.0.1:3001';
    const output = path.resolve(__dirname, '../../docs/screenshots');
    const ready = async () => {
      await page.evaluate(() => document.fonts.ready);
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.theme));
      assert.equal(await page.$eval('html', node => node.lang), 'en');
      assert.equal(await page.$eval('.sidebar-caption', node => node.textContent.trim()), 'Controlled Cryptographic Item');
      assert.equal(await page.$eval('footer', node => node.textContent.trim()), 'CCI-UI · Controlled Cryptographic Item');
    };
    const capture = async filename => {
      await page.setViewport({ width: 1800, height: 1100, deviceScaleFactor: 1 });
      const height = await page.evaluate(() => document.documentElement.scrollHeight);
      // A page-height viewport keeps the fixed sidebar intact in the capture.
      await page.setViewport({ width: 1800, height, deviceScaleFactor: 1 });
      await page.screenshot({ path: path.join(output, filename), fullPage: true });
    };
    const login = async identity => {
      await page.goto(`${base}/login`, { waitUntil: 'networkidle0' });
      assert.deepEqual(await page.select('#identity', identity), [identity]);
      await page.click('input[type=submit]');
      await page.waitForFunction(() => !location.pathname.includes('login'));
      await ready();
    };
    const captureCa = async () => {
      await page.goto(base + '/ca_inventories', { waitUntil: 'networkidle0' });
      await ready();
      await page.waitForSelector('#zone_a-authorities-tab[aria-selected="true"]');
      assert.equal(await page.$$eval('#zone_a-authorities-panel tr[data-depth="2"]', rows => rows.length), 1);
      const badges = await page.$$eval('#zone_a-authorities-panel .badge', nodes => nodes.map(node => node.textContent.trim()));
      for (const state of ['Expired', 'Not yet valid', 'Expiring soon']) assert(badges.includes(state), state);
      assert.equal(await page.$eval('.ca-output td', node => getComputedStyle(node).whiteSpace), 'nowrap');
      await capture('ca-certificates.png');
      await page.click('#zone_a-issues-tab');
      await page.waitForSelector('#zone_a-issues-panel:not([hidden])');
      assert((await page.$eval('#zone_a-issues-panel', node => node.textContent)).includes('No gaps detected'));
      await page.click('#zone_a-hiera-tab');
      await page.waitForSelector('#zone_a-hiera-panel:not([hidden])');
      const yaml = await page.$eval('#zone_a-hiera-panel pre', node => node.textContent);
      assert(!yaml.includes('Retired'));
      assert(!yaml.includes('Future'));
    };
    await login(process.env.CAPTURE_CA_ONLY === '1' ? 'zone_a_reader' : 'all:writer');
    if (process.env.CAPTURE_CA_ONLY === '1') {
      await captureCa();
      assert.deepEqual(errors, []);
      console.log('Updated ca-certificates.png; hierarchy, validity badges and tabs verified.');
      return;
    }
    await page.goto(`${base}/certificates?sort=name`, { waitUntil: 'networkidle0' });
    await ready();
    const headers = await page.$$eval('thead th', cells => cells.map(cell => cell.textContent.trim()));
    assert(headers.includes('Hosts'));
    assert(headers.includes('Puppet status'));
    const portal = await page.$eval('a.certificate-name', () => {
      const link = [...document.querySelectorAll('a.certificate-name')].find(a => a.textContent === 'portal.example.test');
      return { url: link.href, hosts: link.closest('tr').querySelector('.puppetdb-host-count').textContent.trim() };
    });
    assert.equal(portal.hosts, '3');
    assert((await page.$$eval('tbody tr', rows => rows.length)) >= 6);
    if (process.env.CAPTURE_DETAILS_ONLY !== '1') {
      await capture('overview.png');
      await captureCa();
    }

    await page.goto(portal.url, { waitUntil: 'networkidle0' });
    await page.click('.theme-toggle');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'slate');
    await ready();
    const hosts = await page.$$eval('#puppetdb-hosts li', nodes => nodes.map(node => node.textContent));
    assert.deepEqual(hosts, ['proxy01.example.test', 'web01.example.test', 'web02.example.test']);
    assert.equal(await page.$eval('.status-actions input[type=submit]', node => node.value), 'Save status');
    assert.equal(await page.$eval('.status-actions a', node => node.textContent), 'Archive');
    assert.equal(await page.$$eval('.certificate-chain tr[data-depth]', rows => rows.length), 3);
    assert.equal(await page.$eval('.certificate-chain tr[data-depth="2"]', node => node.getAttribute('aria-current')), 'true');
    assert.equal(await page.$eval('.certificate-chain td', node => getComputedStyle(node).whiteSpace), 'nowrap');
    assert.equal(await page.$$eval('.certificate-chain thead th', nodes => nodes.length), 3);
    await capture('details.png');
    // Exercise long subjects without changing the captured application screenshot.
    const originalSubjects = await page.$$eval('.certificate-chain .ca-subject-text a', nodes => nodes.map(node => node.textContent));
    await page.$$eval('.certificate-chain .ca-subject-text a', nodes => {
      nodes.forEach(node => { node.textContent = 'CN=Long demonstration certificate subject '.repeat(12); });
    });
    for (const width of [1800, 1024, 600, 390, 320]) {
      await page.setViewport({ width, height: 1100, deviceScaleFactor: 1 });
      const layout = await page.$eval('.certificate-chain', panel => {
        const output = panel.querySelector('.ca-output');
        const subject = panel.querySelector('.ca-subject-text');
        const right = output.getBoundingClientRect().right;
        return {
          fits: output.scrollWidth <= output.clientWidth + 1,
          validityVisible: [...panel.querySelectorAll('td:nth-child(3)')].every(cell =>
            cell.getBoundingClientRect().right <= right + 1 &&
            cell.scrollWidth <= cell.clientWidth + 1),
          ellipsis: getComputedStyle(subject).textOverflow,
          truncated: subject.scrollWidth > subject.clientWidth,
        };
      });
      assert(layout.fits, 'Chain overflow at ' + width);
      assert(layout.validityVisible, 'Validity clipped at ' + width);
      assert.equal(layout.ellipsis, 'ellipsis');
      assert(layout.truncated, 'Long subject not truncated at ' + width);
    }
    await page.$$eval('.certificate-chain .ca-subject-text a', (nodes, values) => {
      nodes.forEach((node, index) => { node.textContent = values[index]; });
    }, originalSubjects);
    await page.setViewport({ width: 1800, height: 1100, deviceScaleFactor: 1 });
    if (process.env.CAPTURE_DETAILS_ONLY === '1') {
      assert.deepEqual(errors, []);
      console.log('Updated details.png; nested chain, selected certificate and export/status controls verified.');
      return;
    }

    await page.click('.account input[type=submit], .account button.text-button');
    await page.waitForFunction(() => location.pathname === '/login');
    await login('all:auditor');
    await page.goto(`${base}/audit_events`, { waitUntil: 'networkidle0' });
    await page.click('.theme-toggle');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'default');
    await ready();
    // The top rows include the newest archive/status/export events.
    const audit = await page.$eval('.audit-table', node => node.textContent);
    assert(audit.includes('Certificate archived'));
    assert(audit.includes('Puppet status changed'));
    assert(audit.includes('Certificates exported'));
    await capture('audit.png');
    assert.deepEqual(errors, []);
    console.log('Updated overview.png, details.png, ca-certificates.png and audit.png; host counts, names and controls verified.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
