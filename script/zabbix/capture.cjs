// Capture the real disposable Zabbix UI. No DOM or stylesheet modifications.
const assert = require('node:assert/strict');
const path = require('node:path');
const puppeteer = require(process.env.PUPPETEER_MODULE || 'puppeteer');
const base = 'http://127.0.0.1:18074';

(async () => {
  const browser = await puppeteer.launch({
    headless: true,
    ...(process.env.PUPPETEER_EXECUTABLE_PATH ? { executablePath: process.env.PUPPETEER_EXECUTABLE_PATH } : {}),
  });
  try {
    const page = await browser.newPage();
    page.on('dialog', dialog => dialog.accept());
    await page.setViewport({ width: 1800, height: 1100, deviceScaleFactor: 1 });
    await page.setExtraHTTPHeaders({ 'Accept-Language': 'en-US,en;q=0.9' });
    await page.goto(`${base}/index.php`, { waitUntil: "domcontentloaded" });
    await page.type('#name', 'Admin');
    await page.type('#password', 'zabbix');
    await Promise.all([page.waitForNavigation(), page.click('#enter')]);
    const capture = async name => {
      await page.evaluate(() => document.fonts.ready);
      const body = await page.$eval('body', node => node.innerText);
      assert(!body.includes('synthetic-zabbix-test-token'), 'Token must never appear in screenshots');
      await page.screenshot({ path: path.resolve(__dirname, `../../docs/screenshots/zabbix-${name}.png`) });
    };
    await page.goto(`${base}/zabbix.php?action=template.list&filter_name=CCI&filter_set=1`, { waitUntil: "domcontentloaded" });
    await page.click('#js-import');
    const upload = await page.waitForSelector('input[type=file]');
    await upload.uploadFile(path.resolve(__dirname, '../../integrations/zabbix/cci-certificates.yaml'));
    await capture('import');

    await page.goto(`${base}/zabbix.php?action=host.list`, { waitUntil: "domcontentloaded" });
    const href = await page.$$eval('a', links => links.find(link => link.textContent.trim() === 'CCI integration demonstration').href);
    const hostId = new URL(href).searchParams.get('hostid');
    await page.goto(href, { waitUntil: "domcontentloaded" });
    await page.waitForSelector('a[href="#macros-tab"]');
    await page.click('a[href="#macros-tab"]');
    await page.waitForSelector('textarea[name="macros[0][macro]"]');
    await capture('macros');

    await page.goto(`${base}/zabbix.php?action=latest.view&hostids%5B%5D=${hostId}&filter_set=1`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.body.innerText.includes('Valid until'));
    await capture('items');
    await page.goto(`${base}/zabbix.php?action=problem.view&hostids%5B%5D=${hostId}&filter_set=1&show_tags=3`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.body.innerText.includes('expires in less than'));
    await capture('problems');
    console.log('Captured four real Zabbix 7.4.5 screens.');
  } finally {
    await browser.close();
  }
})();
