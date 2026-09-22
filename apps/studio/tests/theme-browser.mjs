import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, extname } from 'node:path';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { build } from 'vite';
import { chromium, expect } from '@playwright/test';

const root = resolve(import.meta.dirname, '..');
const artifacts = await mkdtemp(join(tmpdir(), 'rendprop-theme-browser-'));
const dist = join(artifacts, 'dist');
const fixtures = ['creative', 'business', 'listing-workflow', 'cloud-editor', 'cloud-planner'];
const receipt = {
  status: 'running',
  proof: 'Actual Studio CSS and AppearanceSelector, with isolated local workflow fixtures. All non-local browser requests are aborted; fixture media is intentionally unavailable. No customer data, provider, or account operation.',
  appearance: [], contrast: [], layouts: [], errors: [],
  sourceFiles: Object.fromEntries(await Promise.all(['src/styles.css', 'src/Appearance.tsx', 'src/theme.ts', 'src/editor/editor.css', 'src/planner.css', 'src/features/creative/creative.css', 'src/features/business/business.css', 'src/features/listings/listings.css', 'src/features/sync/reel.css'].map(async path => [path, createHash('sha256').update(await readFile(join(root, path))).digest('hex')]))),
};
let browser, server;
const key = 'rendprop.studio.appearance.v1';
try {
  await build({ configFile: false, root, publicDir: false, logLevel: 'error', build: {
    outDir: dist, rollupOptions: { input: [join(root, 'tests/fixtures/appearance.html'), ...fixtures.map(name => join(root, `tests/${name}-fixture.html`))] },
  } });
  server = createServer(async (req, res) => {
    const pathname = resolve(dist, `.${new URL(req.url, 'http://localhost').pathname}`);
    if (!pathname.startsWith(`${dist}/`) || req.method !== 'GET') return res.writeHead(400).end();
    try {
      res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css' })[extname(pathname)] ?? 'application/octet-stream');
      res.end(await readFile(pathname));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const makeContext = async options => {
    const context = await browser.newContext({ serviceWorkers: 'block', ...options });
    await context.route('**/*', route => new URL(route.request().url()).origin === origin && route.request().method() === 'GET' ? route.continue() : route.abort());
    context.on('page', page => page.on('pageerror', error => receipt.errors.push(error.message)));
    return context;
  };
  const context = await makeContext({ colorScheme: 'light' });
  const a = await context.newPage();
  await a.goto(`${origin}/tests/fixtures/appearance.html`);
  const select = a.getByRole('combobox', { name: 'Appearance', exact: true });
  const bg = () => a.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
  await expect(select).toHaveValue('system');
  assert.equal(await bg(), 'rgb(250, 250, 252)');
  receipt.appearance.push('System defaults to native light palette');
  await a.emulateMedia({ colorScheme: 'dark' });
  await expect.poll(bg).toBe('rgb(14, 13, 20)');
  receipt.appearance.push('System follows an OS theme change without reload');
  await select.selectOption('light'); await a.reload();
  await expect(select).toHaveValue('light'); assert.equal(await bg(), 'rgb(250, 250, 252)');
  receipt.appearance.push('Explicit Light persists and overrides dark OS');
  await select.selectOption('dark'); await a.reload();
  await expect(select).toHaveValue('dark'); assert.equal(await bg(), 'rgb(14, 13, 20)');
  receipt.appearance.push('Explicit Dark persists');
  const b = await context.newPage(); await b.goto(`${origin}/tests/fixtures/appearance.html`);
  await b.getByRole('combobox', { name: 'Appearance', exact: true }).selectOption('light');
  await expect(select).toHaveValue('light'); assert.equal(await bg(), 'rgb(250, 250, 252)');
  receipt.appearance.push('Appearance updates across tabs');
  await b.evaluate(key => localStorage.setItem(key, 'unexpected'), key);
  await expect(select).toHaveValue('system');
  receipt.appearance.push('Invalid stored values safely fall back to System');
  await context.close();
  const denied = await makeContext({ colorScheme: 'light' });
  await denied.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error('Storage unavailable'); };
    Storage.prototype.setItem = () => { throw new Error('Storage unavailable'); };
  });
  const blocked = await denied.newPage(); await blocked.goto(`${origin}/tests/fixtures/appearance.html`);
  await blocked.getByRole('combobox', { name: 'Appearance', exact: true }).selectOption('dark');
  assert.equal(await blocked.evaluate(() => getComputedStyle(document.documentElement).backgroundColor), 'rgb(14, 13, 20)');
  receipt.appearance.push('Unavailable browser storage does not prevent appearance changes');
  await denied.close();

  const luminance = rgb => rgb.slice(0, 3).map(x => x / 255).map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4).reduce((sum, value, i) => sum + value * [.2126, .7152, .0722][i], 0);
  for (const scheme of ['light', 'dark']) {
    const c = await makeContext({ colorScheme: scheme, viewport: { width: 1440, height: 1000 } });
    const page = await c.newPage(); await page.goto(`${origin}/tests/fixtures/appearance.html`);
    const pairs = await page.evaluate(() => {
      const root = getComputedStyle(document.documentElement), sample = document.createElement('span'); document.body.appendChild(sample);
      const rgb = key => { sample.style.color = root.getPropertyValue(key); return getComputedStyle(sample).color.match(/[\d.]+/g).map(Number); };
      const names = [['Body', '--ink', '--bg'], ['Card', '--ink', '--surface'], ['Secondary labels', '--muted', '--surface'], ['Purple links', '--accent-text', '--surface'], ['Primary button', '--on-accent', '--accent'], ['Success', '--good', '--good-soft'], ['Warning', '--warn', '--warn-soft'], ['Error', '--bad', '--bad-soft']];
      const pairs = names.map(([label, fg, bg]) => ({ label, fg: rgb(fg), bg: rgb(bg) })); sample.remove(); return pairs;
    });
    for (const pair of pairs) {
      const l = [luminance(pair.fg), luminance(pair.bg)].sort((a, b) => b - a), ratio = (l[0] + .05) / (l[1] + .05);
      assert.ok(ratio >= 4.5, `${scheme} ${pair.label}: ${ratio}`);
      receipt.contrast.push({ scheme, label: pair.label, ratio: Number(ratio.toFixed(2)), minimum: 4.5 });
    }
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      for (const fixture of fixtures) {
        await page.goto(`${origin}/tests/${fixture}-fixture.html`);
        await expect(page.locator('#root')).not.toBeEmpty();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        const result = await page.evaluate(() => ({ bg: getComputedStyle(document.documentElement).backgroundColor, ink: getComputedStyle(document.documentElement).color, overflow: document.documentElement.scrollWidth > innerWidth + 1 }));
        assert.equal(result.bg, scheme === 'light' ? 'rgb(250, 250, 252)' : 'rgb(14, 13, 20)');
        assert.equal(result.ink, scheme === 'light' ? 'rgb(28, 25, 45)' : 'rgb(242, 240, 250)');
        assert.equal(result.overflow, false, `${fixture} ${scheme} ${width} overflows`);
        receipt.layouts.push({ scheme, width, fixture, ...result });
      }
    }
    await c.close();
  }
  assert.deepEqual(receipt.errors, []);
  receipt.status = 'passed';
} catch (error) {
  receipt.status = 'failed'; receipt.failure = String(error.stack ?? error); throw error;
} finally {
  await writeFile(join(artifacts, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify({ status: receipt.status, appearance: receipt.appearance.length, contrast: receipt.contrast.length, layouts: receipt.layouts.length, artifacts }));
  await browser?.close(); await new Promise(done => server ? server.close(done) : done());
}
