const puppeteer = require('puppeteer-core') /* npm i puppeteer-core */;
const http = require('http');
const post = (path) => new Promise((r) => { const q = http.request({ host: 'localhost', port: 9090, path, method: 'POST' }, (res) => { res.resume(); res.on('end', r); }); q.end(); });
const BASE = process.env.BASE || 'http://localhost:8080', SIMPLE = process.env.SIMPLE || 10, VARIABLE = process.env.VARIABLE || 11;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };

(async () => {
  const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new' });
  const page = await browser.newPage();
  page.on('pageerror', (e) => { console.log('PAGEERROR', e.message); fails++; });
  await page.goto('' + BASE + '/?p=' + SIMPLE + '');
  ok(!!(await page.$('.fastflowpe-buy-now')), 'Buy Now button rendered');

  await page.$eval('form.cart input[name=quantity]', (e) => (e.value = 2));
  await page.click('.fastflowpe-buy-now');
  await page.waitForSelector('#fastflowpe-checkout-backdrop iframe', { timeout: 15000 });
  ok(true, 'modal iframe opened');
  const src = await page.$eval('#fastflowpe-checkout-backdrop iframe', (e) => e.src);
  ok(/localhost:9090\/pay\/.+external_app=true/.test(src), 'iframe src is hosted link: ' + src);
  ok(await page.$eval('#fastflowpe-checkout-backdrop iframe', (e) => e.getAttribute('allow') === 'payment *'), 'iframe allow=payment *');
  const stored = await page.evaluate(() => JSON.parse(sessionStorage.getItem('fastflowpe:activeCheckout')));
  ok(stored && stored.id && stored.mode === 'buy_now', 'activeCheckout persisted');
  ok(await page.evaluate(() => document.documentElement.style.overflow === 'hidden'), 'scroll locked');

  // untrusted message from the page itself (origin != checkout origin, source != iframe) must be ignored
  await page.evaluate(() => window.postMessage({ type: 'FASTFLOW_CHECKOUT_CLOSED' }, '*'));
  await sleep(500);
  ok(!!(await page.$('#fastflowpe-checkout-backdrop')), 'foreign postMessage CLOSED ignored');

  // analytics forwarded from the iframe (source match) -> dataLayer
  await page.evaluate(() => { window.dataLayer = []; });
  const frame = page.frames().find((f) => f.url().includes('/pay/'));
  await frame.evaluate(() => parent.postMessage({ type: 'FASTFLOW_CHECKOUT_ANALYTICS_EVENT', provider: 'ga4', eventName: 'purchase_test', params: { a: 1 } }, '*'));
  await sleep(300);
  ok(await page.evaluate(() => window.dataLayer.some((d) => d.event === 'purchase_test')), 'analytics event forwarded to dataLayer');

  // reload resumes the modal + polling
  await page.reload();
  await page.waitForSelector('#fastflowpe-checkout-backdrop iframe', { timeout: 10000 });
  ok(true, 'reload resumed modal');

  // pay, expect success + redirect to order-received
  const slug = src.match(/pay\/([^?]+)/)[1];
  await post(`/_mock/pay/${slug}?mode=prepaid&billing=1549`);
  await page.waitForFunction(() => location.pathname.includes('order-received'), { timeout: 20000 });
  ok(true, 'redirected to order-received: ' + page.url());
  ok(await page.evaluate(() => sessionStorage.getItem('fastflowpe:activeCheckout') === null), 'activeCheckout cleared');

  // variable product: no option chosen -> toast, no request
  await page.goto('' + BASE + '/?p=' + VARIABLE + '');
  await page.click('.fastflowpe-buy-now');
  await page.waitForSelector('.fastflowpe-toast', { timeout: 3000 });
  ok(true, 'variable product without selection shows toast');
  await page.select('select[name=attribute_size]', 'S');
  await sleep(2000);
  await page.click('.fastflowpe-buy-now');
  await page.waitForSelector('#fastflowpe-checkout-backdrop iframe', { timeout: 15000 });
  ok(true, 'variable product with S opens modal');

  // CLOSED from the iframe closes the modal, clears storage
  const f2 = page.frames().find((f) => f.url().includes('/pay/'));
  await f2.click('#close');
  await page.waitForFunction(() => !document.getElementById('fastflowpe-checkout-backdrop'), { timeout: 5000 });
  ok(true, 'iframe CLOSED message closed the modal');
  await sleep(600);
  ok(await page.evaluate(() => sessionStorage.getItem('fastflowpe:activeCheckout') === null), 'storage cleared after close');
  ok(await page.evaluate(() => document.documentElement.style.overflow !== 'hidden'), 'scroll unlocked');

  // cart page button
  await page.goto('' + BASE + '/?p=' + SIMPLE + '');
  await page.click('button.single_add_to_cart_button');
  await sleep(1500);
  await page.goto(BASE + '/cart/');
  await page.click('.fastflowpe-checkout-button');
  await page.waitForSelector('#fastflowpe-checkout-backdrop iframe', { timeout: 15000 });
  ok(true, 'cart button opens modal');
  const src3 = await page.$eval('#fastflowpe-checkout-backdrop iframe', (e) => e.src);
  await post(`/_mock/pay/${src3.match(/pay\/([^?]+)/)[1]}?mode=prepaid&billing=749.5`);
  await page.waitForFunction(() => location.pathname.includes('order-received'), { timeout: 20000 });
  await page.goto(BASE + '/cart/');
  ok(await page.evaluate(() => document.body.innerText.includes('currently empty')), 'cart cleared after cart checkout');

  await browser.close();
  console.log(fails ? `${fails} FAILURES` : 'ALL PASSED');
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error('ERR', e); process.exit(1); });
