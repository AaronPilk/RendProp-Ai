#!/usr/bin/env node
// Validate the committed public HTML, not a second generated copy. Search
// engines and people should see the same claims; preview links must not become
// a dead sign-in button while the separate studio host is still being prepared.
import { readFileSync, readdirSync, statSync, mkdtempSync, writeFileSync } from 'node:fs';
import { resolve, dirname, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';

const DEFAULT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../public');
const PAGES = ['index', 'features', 'pricing', 'compare', 'support', 'studio', 'industries'];
const NEW_PAGES = ['studio', 'industries'];
const ORIGIN = 'https://rendprop.com';
const DYNAMIC_PATHS = new Set(['/terms', '/privacy', '/f/estate-demo']);
const EXPECTED_OFFERS = [
  ['Starter (monthly)', '49', 1], ['Starter (yearly)', '490', 12],
  ['Pro (monthly)', '99', 1], ['Pro (yearly)', '990', 12], ['Team (monthly)', '249', 1],
];
function require(ok, code) { if (!ok) throw new Error(code); }
const sha = value => createHash('sha256').update(value).digest('hex');
const unescape = text => text.replace(/&(?:amp|lt|gt|quot|apos|nbsp);|&#(?:\d+|x[0-9a-f]+);/gi, value => {
  const named = {'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&nbsp;':' '};
  if (value.toLowerCase() in named) return named[value.toLowerCase()];
  return String.fromCodePoint(Number.parseInt(value.slice(value[2].toLowerCase() === 'x' ? 3 : 2, -1), value[2].toLowerCase() === 'x' ? 16 : 10));
});
const text = value => unescape(value.replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
const tags = (html, tag) => [...html.matchAll(new RegExp(`<${tag}\\b[^>]*>`, 'gi'))].map(match => match[0]);
const attr = (tag, name) => { const m = tag.match(new RegExp(`(?:^|\\s)${name}\\s*=\\s*(["'])(.*?)\\1`, 'i')); return m ? unescape(m[2]) : null; };
const canonical = name => ORIGIN + (name === 'index' ? '/' : '/' + name);
function inventory(root) {
  const files = new Map();
  function visit(folder) {
    for (const entry of readdirSync(folder, {withFileTypes:true})) {
      const path = resolve(folder, entry.name), key = relative(root, path).split(sep).join('/');
      require(!entry.isSymbolicLink(), 'inventory:no-symlinks:' + key);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile()) files.set(key, {size:statSync(path).size});
    }
  }
  visit(root);
  for (const file of [...PAGES.map(name => name + '.html'), 'sitemap.xml', 'robots.txt', 'llms.txt', 'assets/site.css', 'assets/site.js', 'assets/rendprop-mark.svg']) {
    require(files.has(file), 'inventory:missing:' + file);
    const buffer = readFileSync(resolve(root, file));
    files.set(file, {size:buffer.length, body:buffer.toString('utf8'), sha256:sha(buffer)});
  }
  return files;
}
export function checkMarketing(files) {
  let assertions = 0;
  const check = (ok, code) => { assertions++; require(ok, code); };
  const documents = new Map();
  const titles = new Set();
  for (const name of PAGES) {
    const html = files.get(name + '.html')?.body;
    check(typeof html === 'string' && html.length > 1000, `${name}:nonempty-html`);
    const scripts = [...html.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
    check(scripts.length > 0, `${name}:schema-present`);
    let graph;
    try { graph = scripts.flatMap(match => { const value = JSON.parse(match[1]); require(value['@context'] === 'https://schema.org', `${name}:schema-context`); return value['@graph'] ?? [value]; }); }
    catch { throw new Error(`${name}:schema-valid-json`); }
    check(graph.length > 0, `${name}:schema-nonempty`);
    const titleMatches = [...html.matchAll(/<title>([\s\S]*?)<\/title>/gi)];
    check(titleMatches.length === 1, `${name}:one-title`);
    const title = text(titleMatches[0][1]);
    check(title.length > 15 && !titles.has(title), `${name}:unique-title`); titles.add(title);
    const meta = tags(html, 'meta');
    const values = (key, value) => meta.filter(tag => attr(tag, key) === value).map(tag => attr(tag, 'content'));
    const links = tags(html, 'link').filter(tag => attr(tag, 'rel') === 'canonical');
    check(links.length === 1 && attr(links[0], 'href') === canonical(name), `${name}:canonical`);
    check(values('property', 'og:url').length === 1 && values('property', 'og:url')[0] === canonical(name), `${name}:og-canonical`);
    check(values('name', 'description').length === 1 && values('name', 'description')[0].length >= 50, `${name}:description`);
    check(values('property', 'og:title')[0]?.length > 10 && values('property', 'og:description')[0]?.length >= 30, `${name}:og-description`);
    check(values('property', 'og:image')[0] === ORIGIN + '/assets/og.jpg', `${name}:og-image`);
    check(values('name', 'twitter:card')[0] === 'summary_large_image', `${name}:social-card`);
    check(values('name', 'robots')[0]?.includes('index, follow') && !values('name', 'robots')[0]?.includes('noindex'), `${name}:crawlable`);
    check(tags(html, 'h1').length === 1, `${name}:one-h1`);
    check(/<html\s+lang="en"/.test(html), `${name}:english-language`);
    check(html.includes('href="/assets/site.css"') && html.includes('src="/assets/site.js"'), `${name}:shared-theme`);
    const logos = tags(html, 'img').filter(tag => attr(tag, 'class')?.split(' ').includes('brand-dot'));
    check(logos.length === 2 && logos.every(tag => attr(tag, 'src') === '/assets/rendprop-mark.svg'), `${name}:exact-brand`);
    const nav = html.match(/<div class="nav-menu" id="navMenu">([\s\S]*?)<\/div>/)?.[1] ?? '';
    for (const path of ['/features', '/studio', '/industries', '/pricing', '/compare', '/support']) check(tags(nav, 'a').some(tag => attr(tag, 'href') === path), `${name}:nav:${path}`);
    check(tags(html, 'button').some(tag => attr(tag, 'id') === 'menuBtn' && attr(tag, 'aria-controls') === 'navMenu'), `${name}:mobile-menu`);
    check(tags(html, 'button').some(tag => attr(tag, 'id') === 'themeBtn'), `${name}:theme-button`);
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
    check(ids.length === new Set(ids).size && ids.includes('main'), `${name}:unique-ids`);
    check(!html.includes('href="https://studio.rendprop.com'), `${name}:no-unreleased-studio-cta`);
    check(!/everything except publishing works without an account|sign in with Apple only when you publish|Apple approves version/i.test(html), `${name}:no-stale-launch-claim`);
    documents.set(name, {html, graph, ids:new Set(ids)});
  }
  // Follow local links through the same clean-URL -> HTML mapping that the
  // public asset host uses; dynamic legal/demo routes are explicitly inventoried.
  for (const [name, doc] of documents) {
    for (const tag of [...tags(doc.html, 'a'), ...tags(doc.html, 'img'), ...tags(doc.html, 'script'), ...tags(doc.html, 'link'), ...tags(doc.html, 'source')]) {
      const raw = attr(tag, 'href') ?? attr(tag, 'src') ?? attr(tag, 'srcset');
      if (raw === null) continue;
      check(!/^(?:javascript|data):/i.test(raw), `${name}:safe-link-scheme`);
      if (/^(?:mailto|tel):/i.test(raw)) continue;
      const url = new URL(raw, canonical(name));
      if (url.origin !== ORIGIN) { check(url.protocol === 'https:', `${name}:external-https`); continue; }
      const pathname = decodeURIComponent(url.pathname);
      let page = pathname === '/' ? 'index' : pathname.slice(1).replace(/\.html$/, '');
      const target = documents.get(page);
      check(Boolean(target) || DYNAMIC_PATHS.has(pathname) || files.has(pathname.slice(1)), `${name}:local-link:${pathname}`);
      if (target && url.hash) check(target.ids.has(decodeURIComponent(url.hash.slice(1))), `${name}:anchor:${pathname}${url.hash}`);
    }
  }
  for (const name of NEW_PAGES) {
    const {html, graph, ids} = documents.get(name);
    check(graph.some(node => node['@type'] === (name === 'studio' ? 'WebPage' : 'CollectionPage') && node.url === canonical(name)), `${name}:page-schema`);
    check(!graph.some(node => ['Review', 'AggregateRating'].includes(node['@type'])), `${name}:no-fake-reviews`);
    const faq = graph.find(node => node['@type'] === 'FAQPage');
    const entries = [...html.matchAll(/<details>\s*<summary>([\s\S]*?)<\/summary>\s*<p>([\s\S]*?)<\/p>\s*<\/details>/g)].map(match => [text(match[1]), text(match[2])]);
    check(entries.length === (name === 'studio' ? 6 : 4) && faq?.mainEntity?.length === entries.length, `${name}:faq-inventory`);
    for (const question of faq.mainEntity) check(entries.some(([title, answer]) => title === question.name && answer === text(question.acceptedAnswer.text)), `${name}:faq-visible-match:${question.name}`);
    if (name === 'industries') {
      const list = graph.find(node => node['@type'] === 'ItemList');
      check(list?.itemListElement?.length === 5, 'industries:five-schema-items');
      for (const section of ['real-estate', 'venues', 'restaurants', 'retail', 'fitness']) {
        check(ids.has(section), 'industries:section:' + section);
        check(list.itemListElement.some(item => item.url === canonical(name) + '#' + section), 'industries:schema-anchor:' + section);
        const sectionHTML = html.match(new RegExp(`<section[^>]*id="${section}"[\\s\\S]*?<\\/section>`))?.[0] ?? '';
        check(text(sectionHTML).split(' ').length >= 90, 'industries:substantive:' + section);
      }
    } else {
      check(html.includes('data-studio-availability') && text(html).includes('studio.rendprop.com'), 'studio:explicit-rollout');
      for (const phrase of ['not automatically synced', 'not a cloud backup', 'does not connect to social accounts', 'browser supports']) check(html.includes(phrase), 'studio:limit:' + phrase);
    }
  }
  const offers = documents.get('pricing').graph.find(node => node['@type'] === 'SoftwareApplication')?.offers;
  check(offers?.length === EXPECTED_OFFERS.length, 'pricing:five-offers');
  for (const [name, price, months] of EXPECTED_OFFERS) {
    const offer = offers.find(value => value.name === name);
    check(offer?.price === price && offer.priceCurrency === 'USD' && offer.priceSpecification?.price === price && offer.priceSpecification?.billingDuration === months, 'pricing:unchanged:' + name);
  }
  for (const name of ['index', 'pricing']) {
    const body = text(documents.get(name).html.replace(/<script[\s\S]*?<\/script>/g, ''));
    for (const price of ['$49', '$99', '$249', '$490', '$990']) check(body.includes(price), `${name}:visible-price:${price}`);
    check(!/\$2,?490/.test(body), `${name}:no-team-annual-sale`);
  }
  const sitemap = files.get('sitemap.xml').body;
  const locs = [...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map(match => match[1]);
  check(locs.length === 10 && new Set(locs).size === 10, 'sitemap:exact-public-inventory');
  for (const name of PAGES) check(locs.includes(canonical(name)), 'sitemap:' + name);
  check(!locs.some(url => url.includes('studio.rendprop.com') || /\/u\//.test(url)), 'sitemap:no-private-workspaces');
  for (const name of NEW_PAGES) check(files.get('llms.txt').body.includes(canonical(name)), 'llms:link:' + name);
  check(files.get('assets/site.css').body.includes('--accent: #7c3aed;') && files.get('assets/site.css').body.includes('html[data-theme="dark"]'), 'brand:shared-palette');
  return {assertions, htmlPages:PAGES.length, newFAQAnswers:10, industrySections:5, offerCount:offers.length};
}

function negativeControls(files) {
  const cases = [
    ['wrong canonical', 'studio.html', 'href="https://rendprop.com/studio"', 'href="https://wrong.invalid/studio"', 'studio:canonical'],
    ['broken schema', 'studio.html', '"@context": "https://schema.org",', '"@context": ,', 'studio:schema-valid-json'],
    ['FAQ mismatch', 'studio.html', '<p>No. The preview calendar is for local planning', '<p>Yes. The preview calendar is for local planning', 'studio:faq-visible-match:'],
    ['missing industry section', 'industries.html', 'id="fitness"', 'id="missing-fitness"', ':anchor:/industries#fitness'],
    ['wrong price', 'pricing.html', '"price": "49"', '"price": "50"', 'pricing:unchanged:Starter (monthly)'],
    ['missing nav', 'support.html', '<a href="/industries">Industries</a>', '<a href="/features">Industries</a>', 'support:nav:/industries'],
    ['dead studio CTA', 'studio.html', 'href="#editor"', 'href="https://studio.rendprop.com"', 'studio:no-unreleased-studio-cta'],
    ['bad local link', 'studio.html', 'href="#editor"', 'href="/missing-studio-page"', 'studio:local-link:/missing-studio-page'],
    ['wrong logo', 'studio.html', 'src="/assets/rendprop-mark.svg"', 'src="/assets/other-logo.svg"', 'studio:exact-brand'],
    ['unsafe URL', 'studio.html', 'href="#editor"', 'href="javascript:void(0)"', 'studio:safe-link-scheme'],
    ['missing sitemap entry', 'sitemap.xml', '<loc>https://rendprop.com/studio</loc>', '<loc>https://rendprop.com/not-studio</loc>', 'sitemap:studio'],
    ['missing page bytes', 'studio.html', '<!doctype html>', '', 'studio:nonempty-html', true],
  ];
  const caught = [];
  for (const [label, file, old, replacement, reason, empty] of cases) {
    const copy = new Map(files), original = files.get(file);
    require(original.body.includes(old), 'self-test:missing-mutation:' + label);
    copy.set(file, {...original, body:empty ? '' : original.body.replace(old, replacement)});
    let error;
    try { checkMarketing(copy); } catch (failure) { error = failure; }
    require(error instanceof Error && error.message.includes(reason), 'self-test:false-green-or-wrong-reason:' + label + ':' + (error?.message ?? 'accepted'));
    caught.push({label, rejection:error.message});
  }
  return caught;
}
async function browserProof(root, files, modulePath) {
  // Optional existing Playwright only: no package installation, user browser,
  // public backend, OAuth session or provider request belongs in a layout test.
  const {chromium} = await import(pathToFileURL(resolve(modulePath)).href);
  require(typeof chromium?.launch === 'function', 'browser:playwright-module');
  const types = {'.html':'text/html; charset=utf-8','.css':'text/css','.js':'text/javascript','.svg':'image/svg+xml','.webp':'image/webp','.jpg':'image/jpeg','.png':'image/png','.mp4':'video/mp4'};
  const server = createServer((req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      const name = pathname === '/' ? 'index.html' : pathname.slice(1);
      const key = files.has(name) ? name : name + '.html';
      if (req.method !== 'GET' || !files.has(key) || key.split('/').includes('..')) { res.writeHead(404).end(); return; }
      const ext = key.slice(key.lastIndexOf('.'));
      res.writeHead(200, {'Content-Type':types[ext] ?? 'text/plain','Cache-Control':'no-store'});
      res.end(readFileSync(resolve(root, key)));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise((done, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', done); });
  const origin = 'http://127.0.0.1:' + server.address().port;
  let browser;
  const artifacts = mkdtempSync(resolve(tmpdir(), 'rendprop-marketing-browser-'));
  const screenshots = [], errors = [], requests = [], checked = [];
  let assertions = 0;
  const check = (ok, code) => { assertions++; require(ok, code); };
  try {
    browser = await chromium.launch({headless:true});
    for (const [width, scheme] of [[360,'light'],[390,'dark'],[1024,'light'],[1440,'dark']]) {
      const context = await browser.newContext({viewport:{width,height:900},colorScheme:scheme,reducedMotion:'reduce'});
      await context.route('**/*', async route => {
        const url = route.request().url(); requests.push(url);
        if (new URL(url).origin !== origin) { errors.push('Unexpected external request: ' + new URL(url).origin); await route.abort(); }
        else await route.continue();
      });
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
      page.on('response', response => { if (response.status() >= 400) errors.push('HTTP ' + response.status() + ' ' + new URL(response.url()).pathname); });
      for (const name of PAGES) {
        const response = await page.goto(origin + (name === 'index' ? '/' : '/' + name), {waitUntil:'networkidle',timeout:15000});
        check(response?.status() === 200, `browser:${name}:HTTP200`);
        check(await page.locator('h1').isVisible(), `browser:${name}:visible-heading`);
        const metrics = await page.evaluate(() => ({viewport:innerWidth, body:document.body.scrollWidth, bodyOverflow:getComputedStyle(document.body).overflowX, root:document.scrollingElement.scrollWidth, buttons:[...document.querySelectorAll('.nav-inner .brand,.nav-inner button,.nav-cta')].filter(el => getComputedStyle(el).display !== 'none').map(el => { const r = el.getBoundingClientRect(); return {left:r.left,right:r.right}; }), wide:[...document.querySelectorAll('main *')].map(el => { const r = el.getBoundingClientRect(); return {tag:el.tagName,class:el.className,left:r.left,right:r.right}; }).filter(r => r.right > innerWidth + 1 && r.left >= 0).slice(0,12)}));
        // Existing decorative orbs paint outside the body but are intentionally
        // clipped. body.scrollWidth is not the document's scrolling width in
        // that case; measure the actual scroll container and require clipping.
        check(metrics.root <= width + 1 && (metrics.body <= width + 1 || ['clip','hidden'].includes(metrics.bodyOverflow)), `browser:${name}:no-page-overflow:${width}:${JSON.stringify(metrics)}`);
        check(metrics.buttons.every(rect => rect.left >= 0 && rect.right <= width + 1), `browser:${name}:nav-fits:${width}`);
        if (width < 900) {
          await page.locator('#menuBtn').click();
          check(await page.locator('#menuBtn').getAttribute('aria-expanded') === 'true', `browser:${name}:menu-opens`);
          check(await page.locator('#navMenu a[href="/studio"]').isVisible() && await page.locator('#navMenu a[href="/industries"]').isVisible(), `browser:${name}:mobile-new-links`);
          await page.keyboard.press('Escape');
          check(await page.locator('#menuBtn').getAttribute('aria-expanded') === 'false', `browser:${name}:menu-closes`);
        }
        if (NEW_PAGES.includes(name)) {
          await page.locator('details summary').first().click();
          check(await page.locator('details').first().getAttribute('open') !== null, `browser:${name}:faq-opens`);
          await page.locator('details summary').first().click();
          const priorTheme = await page.locator('html').getAttribute('data-theme');
          await page.locator('#themeBtn').click();
          // Auto is a real third mode: dark -> auto intentionally REMOVES the
          // attribute. Require the next state and its user-visible label.
          const nextTheme = priorTheme === null ? 'light' : priorTheme === 'light' ? 'dark' : null;
          check(await page.locator('html').getAttribute('data-theme') === nextTheme && (await page.locator('#themeBtn').getAttribute('aria-label')).includes('Theme: ' + (nextTheme ?? 'auto')), `browser:${name}:theme-works`);
          // Restore the declared scheme before retaining the visual artifact.
          await page.evaluate(s => { document.documentElement.setAttribute('data-theme', s); localStorage.setItem('rp-theme', s); }, scheme);
          if (([390,1024].includes(width) && name === 'studio') || ([360,1440].includes(width) && name === 'industries')) {
            const path = resolve(artifacts, `${name}-${width}-${scheme}.png`);
            await page.evaluate(() => window.scrollTo({top:0,behavior:'instant'}));
            await page.waitForFunction(() => scrollY === 0);
            await page.screenshot({path,fullPage:true});
            screenshots.push({path,sha256:sha(readFileSync(path))});
          }
        }
        checked.push({page:name,width,scheme});
      }
      // A click must navigate, not merely point at a syntactically valid URL.
      if (width < 900) await page.locator('#menuBtn').click();
      await page.locator('#navMenu a[href="/studio"]').click();
      check(new URL(page.url()).pathname === '/studio', 'browser:studio-navigation');
      check(await page.locator('[data-studio-availability]').isVisible(), 'browser:rollout-visible');
      await context.close();
    }
    check(errors.length === 0, 'browser:no-console-page-http-external-errors:' + errors.join(';'));
    return {assertions,renderedPages:checked.length,checked,screenshots,requests:requests.length,errors,artifacts,network:'loopback static assets only',limits:['Chromium only; not Safari or a physical phone','Source static server; not Cloudflare response/CSP headers','No deployment, auth, editing or paid-provider test']};
  } finally {
    if (browser) await browser.close();
    await new Promise(done => server.close(done));
  }
}
const args = process.argv.slice(2);
let root = DEFAULT_ROOT, browserModule = null;
while (args.length) {
  const flag = args.shift(), value = args.shift();
  require(value && ['--public-dir','--browser-module'].includes(flag), 'Usage: node scripts/check-marketing.mjs [--public-dir PATH] [--browser-module EXISTING_PLAYWRIGHT_INDEX_MJS]');
  if (flag === '--public-dir') root = resolve(value); else browserModule = value;
}
try {
  const files = inventory(root);
  const result = checkMarketing(files);
  const controls = negativeControls(files);
  const visual = browserModule ? await browserProof(root, files, browserModule) : null;
  const report = {ok:true, root, observedAt:new Date().toISOString(), node:process.version, scriptSHA256:sha(readFileSync(fileURLToPath(import.meta.url))), ...result, negativeControls:controls, browser:visual, sourceHashes:Object.fromEntries([...files].filter(([,value]) => value.sha256).map(([name,value]) => [name,value.sha256])), limits:['Static source HTML/link/schema validation; browser proof only when explicitly requested', 'No deployed host, DNS, OAuth, indexing or editor-functionality proof', 'Existing third-party comparison claims are not re-researched by this gate']};
  if (visual) { report.receipt = resolve(visual.artifacts, 'receipt.json'); writeFileSync(report.receipt, JSON.stringify(report, null, 2) + '\n', {flag:'wx',mode:0o600}); }
  console.log(JSON.stringify(report, null, 2));
} catch (error) { console.error('MARKETING_CHECK_FAILED: ' + error.message); process.exitCode = 1; }
