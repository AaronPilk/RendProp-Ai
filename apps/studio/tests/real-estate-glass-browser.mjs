#!/usr/bin/env node
// Actual App and production stylesheet order, using only synthetic connected services.
// No provider calls, release build, deployment, account mutation or physical device.
// Usage: node tests/real-estate-glass-browser.mjs [evidence-directory]
// STUDIO_BROWSER_EXECUTABLE and STUDIO_WEBKIT_EXECUTABLE may select installed engines.
// STUDIO_GLASS_SPACING_ROUTES optionally narrows diagnostics (e.g. library);
// default coverage includes all seven routes, and receipts record any subset.
// STUDIO_GLASS_ENGINES may narrow a targeted follow-up to chromium or webkit.
// STUDIO_GLASS_SPACING_FOCUS=large-text runs only 900/1024px at 200% text.
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { build } from 'vite';
import { chromium, webkit, expect } from '@playwright/test';
import { previewBuildOptions, previewCsp } from '../scripts/real-estate-playground-guards.mjs';

const root = resolve(import.meta.dirname, '..');
const artifacts = process.argv[2] ? resolve(process.argv[2]) : await mkdtemp(join(tmpdir(), 'rendprop-real-estate-glass-'));
await mkdir(artifacts, { recursive: true });
const dist = join(await mkdtemp(join(tmpdir(), 'rendprop-real-estate-glass-build-')), 'dist');
const entry = 'tests/fixtures/real-estate-playground.html';
const appearanceKey = 'rendprop.studio.appearance.v1';
const receipt = {
  status: 'running',
  proof: 'Actual App with synthetic connected services and production stylesheet order. Loopback static assets only; unexpected network is blocked. Visual checks do not establish production, Safari-device or native acceptance.',
  engines: [], checks: [], measurements: [], visuals: [], errors: [], unexpectedRequests: [], limitations: [],
  spacingRoutes: process.env.STUDIO_GLASS_SPACING_ROUTES?.split(',') ?? 'all seven main routes',
  spacingFocus: process.env.STUDIO_GLASS_SPACING_FOCUS ?? 'full',
  requestedEngines: process.env.STUDIO_GLASS_ENGINES?.split(',') ?? ['chromium', 'webkit'],
  scope: 'Desktop web Studio: 900/1024/1280/1440/1920px; 200% text at 900/1024/1440px; resized desktop left-navigation checks at 640/768px. No phone dock or native-app acceptance.',
  sourceFiles: Object.fromEntries(await Promise.all(['src/App.tsx', 'src/Appearance.tsx', 'src/styles.css', 'src/design/studio.css', 'src/design/real-estate-glass.css', 'tests/fixtures/connected-runtime.tsx', 'tests/fixtures/real-estate-playground.tsx', 'tests/fixtures/real-estate-playground.css', 'tests/real-estate-glass-browser.mjs'].map(async path => [path, createHash('sha256').update(await readFile(join(root, path))).digest('hex')]))),
};
let server;
const check = (engine, name) => { receipt.checks.push({ engine, name }); console.log(`ok - ${engine}: ${name}`); };
const near = (a, b, tolerance, message) => assert.ok(Math.abs(a - b) <= tolerance, `${message}: ${a} vs ${b}`);

async function settled(page) {
  await page.waitForFunction(() => document.getAnimations().every(a => a.playState !== 'running' || a.effect?.getTiming().iterations === Infinity));
  await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))));
}
async function screenshot(page, engine, label, fullPage = false) {
  await settled(page);
  const filename = `${engine}-${label}.png`;
  await page.screenshot({ path: join(artifacts, filename), animations: 'disabled', fullPage });
  receipt.visuals.push({ engine, label, filename });
}
async function geometry(page, engine, label) {
  await settled(page);
  const result = await page.evaluate(() => {
    const rect = e => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }; };
    const visible = e => {
      for (let p = e.parentElement; p; p = p.parentElement) if (p.matches('details:not([open])') && !p.querySelector(':scope > summary')?.contains(e)) return false;
      return e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    };
    const rail = document.querySelector('.studio-glass > .sidebar');
    const header = document.querySelector('.studio-glass .topbar');
    const main = document.querySelector('.studio-glass #main');
    const notice = document.querySelector('.real-estate-preview-notice');
    const railStyle = getComputedStyle(rail), railMaterial = getComputedStyle(rail, '::before');
    const controls = [...header.querySelectorAll('button,select')].filter(visible).map(e => ({ name: e.getAttribute('aria-label') || e.textContent.trim(), ...rect(e) }));
    const nav = [...rail.querySelectorAll('.nav-item,summary,.studio-rail-toggle')].filter(visible).map(e => ({ name: e.getAttribute('aria-label') || e.textContent.trim(), ...rect(e) }));
    const overflow = [...main.querySelectorAll('*')].filter(visible).map(e => ({ tag: e.tagName, className: e.className, text: e.textContent.trim().slice(0, 80), ...rect(e) })).filter(r => r.right > innerWidth + 1 || r.left < -1).slice(0, 15);
    return { viewport: { width: innerWidth, height: innerHeight }, scrollWidth: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth), rail: rect(rail), railMaterialHeight: parseFloat(railMaterial.height), railMaterialWidth: parseFloat(railMaterial.width), railBackdrop: railStyle.backdropFilter || railStyle.webkitBackdropFilter || 'none', railMaterialBackdrop: railMaterial.backdropFilter || railMaterial.webkitBackdropFilter || 'none', reducedMaterial: matchMedia('(prefers-reduced-transparency: reduce), (prefers-contrast: more), (forced-colors: active)').matches, notice: notice ? rect(notice) : null, header: rect(header), main: rect(main), controls, nav, overflow };
  });
  receipt.measurements.push({ engine, label, ...result });
  assert.ok(result.scrollWidth <= result.viewport.width + 1, `${label}: horizontal page overflow (${result.scrollWidth})`);
  assert.ok(result.main.width > Math.min(220, result.viewport.width - 48), `${label}: usable main content width`);
  assert.ok(result.rail.left >= -1 && result.rail.right <= result.viewport.width + 1, `${label}: left rail stays horizontally inside viewport`);
  // The material fills the interior of the two 1px borders. Computed CSS height
  // rounds to three decimals while DOMRect may retain more precision.
  assert.ok(result.railMaterialHeight >= result.rail.height - 2.01, `${label}: material covers the complete left rail, not an inherited short strip (${result.railMaterialHeight} vs ${result.rail.height})`);
  near(result.railMaterialWidth, result.rail.width, 2.01, `${label}: material covers rail width`);
  assert.equal(result.railBackdrop, 'none', `${label}: rail must not inherit a blur that traps the fixed material layer`);
  assert.ok(result.reducedMaterial ? result.railMaterialBackdrop === 'none' : /blur\(28px\)/.test(result.railMaterialBackdrop), `${label}: rail material respects standard backdrop-filter support: ${result.railMaterialBackdrop}`);
  for (const control of result.controls) {
    assert.ok(control.left >= -1 && control.right <= result.viewport.width + 1, `${label}: ${control.name} stays inside viewport`);
    assert.ok(control.height >= 39, `${label}: ${control.name} has a usable target`);
  }
  for (let i = 0; i < result.controls.length; i++) for (let j = i + 1; j < result.controls.length; j++) {
    const a = result.controls[i], b = result.controls[j];
    const overlapX = Math.min(a.right, b.right) - Math.max(a.left, b.left);
    const overlapY = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    assert.ok(overlapX <= 1 || overlapY <= 1, `${label}: header controls overlap: ${a.name} / ${b.name}`);
  }
  assert.ok(result.main.top >= result.header.bottom - 1, `${label}: main content starts below header`);
  assert.ok(result.main.left >= result.rail.right + 7, `${label}: left rail does not cover content`);
  assert.ok(result.rail.bottom <= result.viewport.height - 7, `${label}: rail reserves viewport bottom space`);
  assert.ok(result.rail.top < result.viewport.height / 2 && result.rail.height > result.rail.width * 2, `${label}: navigation stays a vertical left rail, not a bottom dock`);
  if (result.notice) assert.ok(result.rail.top >= result.notice.bottom + 7, `${label}: local preview notice does not cover the rail`);
  return result;
}
async function assertTextFitsRail(page, engine, label) {
  const measurements = await page.locator('.studio-glass .sidebar .nav-item').evaluateAll(buttons => buttons.filter(b => b.getClientRects().length).map(button => {
    const bounds = button.getBoundingClientRect();
    const labels = [...button.querySelectorAll('.nav-label-short,.nav-label-full')].filter(el => el.getClientRects().length);
    return { name: button.getAttribute('aria-label'), left: bounds.left, right: bounds.right, text: labels.map(el => { const range = new Range(); range.selectNodeContents(el); return [...range.getClientRects()].map(r => ({ left: r.left, right: r.right })); }).flat() };
  }));
  receipt.measurements.push({ engine, label, labels: measurements });
  for (const item of measurements) for (const text of item.text) assert.ok(text.left >= item.left - 1 && text.right <= item.right + 1, `${label}: ${item.name} label is clipped`);
}
async function opaque(page, selector, label) {
  const surfaces = await page.locator(selector).evaluateAll(els => els.filter(el => el.getClientRects().length).map(el => {
    const style = getComputedStyle(el);
    return { name: el.className, background: style.backgroundColor, backdrop: style.backdropFilter || style.webkitBackdropFilter || 'none' };
  }));
  assert.ok(surfaces.length, `${label}: expected surface exists`);
  for (const surface of surfaces) {
    const numbers = surface.background.match(/[\d.]+/g)?.map(Number) ?? [];
    assert.ok(numbers.length === 3 || numbers.length === 4 && numbers[3] === 1, `${label}: translucent ${surface.name}: ${surface.background}`);
    assert.equal(surface.backdrop, 'none', `${label}: blur remains on ${surface.name}`);
  }
  return surfaces;
}
async function materialChrome(page, engine, label) {
  // Rail material is a separate decorative pseudo-element. Inspect its rendered
  // layer as well as the accessible control surfaces.
  const material = await page.evaluate(() => {
    const selectors = ['.studio-glass .studio-wordmark', '.studio-glass .studio-appearance-pills', '.studio-glass .account-button', '.studio-glass .business-switch-trigger', '.studio-glass .sidebar', '.studio-glass .app-home-hero'];
    return selectors.flatMap(selector => [...document.querySelectorAll(selector)].filter(el => el.getClientRects().length).map(el => {
      const read = pseudo => { const s = getComputedStyle(el, pseudo); return { content: s.content, background: s.backgroundColor, backdrop: s.backdropFilter || s.webkitBackdropFilter || 'none', display: s.display }; };
      return { selector, element: read(null), before: read('::before') };
    }));
  });
  receipt.measurements.push({ engine, label, material });
  for (const surface of material) {
    const layers = [surface.element, ...(surface.before.content !== 'none' && surface.before.display !== 'none' ? [surface.before] : [])];
    assert.ok(layers.every(layer => layer.backdrop === 'none'), `${label}: ${surface.selector} retains blur`);
    assert.ok(layers.some(layer => /^rgb\(/.test(layer.background) || /^rgba\([^)]*,\s*1\)$/.test(layer.background)), `${label}: ${surface.selector} lacks a solid accessible layer`);
  }
}
async function spacingSnapshot(page, engine, label) {
  await settled(page);
  const result = await page.evaluate(() => {
    const visible = el => {
      // Closed details retain descendant layout boxes in some engines; those
      // boxes are not rendered controls and must not be treated as overlaps.
      for (let p = el.parentElement; p; p = p.parentElement) if (p.matches('details:not([open])') && !p.querySelector(':scope > summary')?.contains(el)) return false;
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && s.display !== 'none';
    };
    const box = el => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }; };
    const name = el => el.getAttribute('aria-label') || el.textContent.trim().replace(/\s+/g, ' ').slice(0, 70) || el.tagName;
    const record = el => ({ name: name(el), className: el.className, ...box(el) });
    const issues = [], gaps = [], alignment = [];
    const pair = (a, b) => ({ x: Math.max(b.left - a.right, a.left - b.right), y: Math.max(b.top - a.bottom, a.top - b.bottom) });
    const separated = (a, b, minimum, group) => {
      const distance = pair(a, b);
      if (distance.x < -.5 && distance.y < -.5) issues.push({ issue: 'overlapping controls', group, a, b });
      else if (distance.x < -.5 && distance.y < minimum - .5 || distance.y < -.5 && distance.x < minimum - .5) issues.push({ issue: `controls need ${minimum}px separation`, group, distance, a, b });
    };
    const controls = [...document.querySelectorAll('#main button,#main input,#main select,#main textarea,#main summary')].filter(visible);
    for (const el of controls) {
      const r = record(el);
      const scrollAncestor = [...function* () { for (let p = el.parentElement; p && p.id !== 'main'; p = p.parentElement) yield p; }()].some(p => ['auto', 'scroll'].includes(getComputedStyle(p).overflowX) && p.scrollWidth > p.clientWidth);
      if (!scrollAncestor && (r.left < -1 || r.right > innerWidth + 1)) issues.push({ issue: 'control outside horizontal viewport', control: r });
      if (el.matches('button,summary') && !el.querySelector('button,input,select,textarea')) {
        const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        for (let node = walk.nextNode(); node; node = walk.nextNode()) {
          if (!node.textContent.trim() || !visible(node.parentElement)) continue;
          const range = new Range(); range.selectNodeContents(node);
          const textRects = [...range.getClientRects()].filter(t => t.width > 1 && t.height > 1);
          if (textRects.some(t => t.left < r.left - 1 || t.right > r.right + 1 || t.top < r.top - 1 || t.bottom > r.bottom + 1)) issues.push({ issue: 'control label escapes bounds', control: r, text: node.textContent.trim(), textRects: textRects.map(t => ({ left: t.left, right: t.right, top: t.top, bottom: t.bottom })) });
        }
      }
    }
    for (let i = 0; i < controls.length; i++) for (let j = i + 1; j < controls.length; j++) {
      if (controls[i].contains(controls[j]) || controls[j].contains(controls[i])) continue;
      separated(record(controls[i]), record(controls[j]), 0, 'main interactive controls');
    }
    for (const selector of ['.topbar', '.top-actions', '.studio-appearance-pills']) {
      const group = document.querySelector(selector), children = [...group.children].filter(visible).map(record), bounds = box(group);
      const minimum = selector === '.studio-appearance-pills' ? 2 : 8;
      for (let i = 0; i < children.length; i++) for (let j = i + 1; j < children.length; j++) separated(children[i], children[j], minimum, selector);
      const rows = [];
      for (const child of children.sort((a, b) => a.top - b.top || a.left - b.left)) {
        let row = rows.find(row => Math.min(row.bottom, child.bottom) - Math.max(row.top, child.top) > Math.min(row.bottom - row.top, child.height) / 2);
        if (!row) { row = { top: child.top, bottom: child.bottom, children: [] }; rows.push(row); }
        row.children.push(child);
      }
      for (const row of rows) {
        const centers = row.children.map(c => (c.top + c.bottom) / 2);
        if (Math.max(...centers) - Math.min(...centers) > 2) issues.push({ issue: 'header row is not vertically centered', group: selector, row });
        if (selector === '.top-actions' && rows.length > 1) {
          const justify = getComputedStyle(group).justifyContent;
          if (justify === 'flex-start' && Math.abs(Math.min(...row.children.map(c => c.left)) - bounds.left) > 1) issues.push({ issue: 'wrapped header row is not left aligned', row, bounds });
          if (justify === 'flex-end' && Math.abs(Math.max(...row.children.map(c => c.right)) - bounds.right) > 1) issues.push({ issue: 'wrapped header row is not right aligned', row, bounds });
        }
      }
      alignment.push({ selector, rows });
    }
    for (const selector of ['.button-row', '.lw-actions', '.creative-actions', '.business-actions', '.planner-form-actions', '.planner-week-buttons', '.lw-tabs', '.creative-tabs', '.business-nav']) {
      for (const group of document.querySelectorAll(`#main ${selector}`)) {
        const children = [...group.querySelectorAll(':scope > button,:scope > input,:scope > select')].filter(visible).map(record);
        for (let i = 0; i < children.length; i++) for (let j = i + 1; j < children.length; j++) separated(children[i], children[j], 6, selector);
      }
    }
    for (const selector of ['[aria-label="Business workspace"] + .settings-grid', '.batch-photo-studio']) {
      for (const section of document.querySelectorAll(`#main ${selector}`)) {
        const before = section.previousElementSibling;
        if (!before || !visible(before) || !visible(section)) continue;
        const a = record(before), b = record(section), gap = b.top - a.bottom;
        gaps.push({ group: selector, gap });
        if (gap < 19.5) issues.push({ issue: 'Adjacent workspace sections need 20px separation', group: selector, gap, a, b });
      }
    }
    const dashboard = document.querySelector('.app-dashboard');
    if (dashboard) {
      const sections = [...dashboard.children].filter(visible).map(record);
      for (let i = 1; i < sections.length; i++) {
        const gap = sections[i].top - sections[i - 1].bottom;
        gaps.push({ group: 'Home sections', gap });
        if (gap < 19.5) issues.push({ issue: 'Home sections need 20px separation', gap, a: sections[i - 1], b: sections[i] });
      }
      for (const section of dashboard.querySelectorAll(':scope > section:has(> .app-property-grid)')) {
        const children = [...section.children].filter(visible).map(record);
        for (let i = 1; i < children.length; i++) {
          const gap = children[i].top - children[i - 1].bottom;
          gaps.push({ group: 'Home collection header/grid/footer', gap });
          if (gap < 19.5) issues.push({ issue: 'Home collection header/grid/footer need 20px separation', gap, a: children[i - 1], b: children[i] });
        }
        const grid = section.querySelector('.app-property-grid'), cards = [...grid.children].filter(visible).map(record);
        for (let i = 0; i < cards.length; i++) for (let j = i + 1; j < cards.length; j++) separated(cards[i], cards[j], 20, 'Home listing cards');
      }
      for (const section of dashboard.querySelectorAll('.app-all-tools[open] > div > section')) {
        const children = [...section.children].filter(visible).map(record);
        for (let i = 1; i < children.length; i++) {
          const gap = children[i].top - children[i - 1].bottom;
          gaps.push({ group: 'Home expanded tool section', gap });
          if (gap < 19.5) issues.push({ issue: 'Home expanded tool section needs 20px separation', gap, a: children[i - 1], b: children[i] });
        }
      }
    }
    return { viewport: { width: innerWidth, height: innerHeight }, controlCount: controls.length, issues, gaps, alignment };
  });
  receipt.measurements.push({ engine, label, spacing: result });
  return result.issues;
}
async function runEngine(name, type, executablePath, origin) {
  const engine = { name, status: 'running' }; receipt.engines.push(engine);
  const browser = await type.launch({ headless: true, ...(executablePath ? { executablePath } : {}) });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, colorScheme: 'light', serviceWorkers: 'block' });
  const page = await context.newPage(); page.setDefaultTimeout(15_000);
  const route = route => {
    const request = route.request(), u = new URL(request.url());
    if (u.origin === origin && ['GET', 'HEAD'].includes(request.method())) return route.continue();
    receipt.unexpectedRequests.push({ engine: name, method: request.method(), origin: u.origin, path: u.pathname }); return route.abort();
  };
  await context.route('**/*', route);
  page.on('pageerror', error => receipt.errors.push({ engine: name, message: error.message }));
  const appearance = choice => page.locator('.topbar').getByRole('button', { name: choice, exact: true });
  const nav = choice => page.getByRole('navigation', { name: 'Studio navigation', exact: true }).getByRole('button', { name: choice, exact: true });
  const go = async (choice, expected) => {
    if (!await nav(choice).isVisible()) await page.locator('.secondary-navigation > summary').click();
    await nav(choice).click(); await expect(page.locator('.studio-glass')).toHaveAttribute('data-studio-page', expected); await settled(page);
  };
  try {
    engine.userAgent = await page.evaluate(() => navigator.userAgent);
    await page.goto(`${origin}/${entry}?view=overview`);
    await expect(page.locator('.studio-glass')).toHaveAttribute('data-studio-page', 'overview');
    await expect(page.locator('.account-button')).toBeVisible();
    await expect(page.locator('.app-home-hero')).toBeVisible();
    const initialRows = await page.evaluate(() => window.studioFixture.listingRows());
    assert.ok(initialRows.length >= 2, 'Connected fixture includes multiple properties');
    await expect(page.locator('.studio-glass-backdrop')).toHaveAttribute('aria-hidden', 'true');
    const scene = await page.locator('.studio-glass-backdrop').evaluate(el => { const s = getComputedStyle(el); return { pointerEvents: s.pointerEvents, background: s.backgroundImage, images: [...el.querySelectorAll('img')].map(i => ({ complete: i.complete, width: i.naturalWidth })) }; });
    assert.equal(scene.pointerEvents, 'none');
    assert.ok(scene.background !== 'none' || scene.images.some(i => i.complete && i.width > 0), 'Decorative scene loaded locally');
    check(name, 'actual connected App opens Home with multiple synthetic properties and a noninteractive scene');

    const navigation = page.getByRole('navigation', { name: 'Studio navigation', exact: true });
    const expectedPrimary = ['Home', 'Create', 'My Listings', 'Media', 'Business'];
    assert.deepEqual(await navigation.locator(':scope > button').evaluateAll(buttons => buttons.map(button => button.getAttribute('aria-label'))), expectedPrimary, 'Primary navigation follows the same Home-first DOM order');
    assert.deepEqual(await navigation.locator('.secondary-navigation-menu button').evaluateAll(buttons => buttons.map(button => button.getAttribute('aria-label'))), ['AI tools', 'Content planner'], 'More tools contains only secondary tools');
    await expect(navigation.locator('.secondary-navigation-menu').getByRole('button', { name: 'Home', exact: true })).toHaveCount(0);
    await expect(nav('Home')).toHaveAttribute('aria-current', 'page');
    assert.equal(await navigation.locator('.secondary-navigation').evaluate(el => el.open), false, 'Home initially leaves More tools closed');
    for (const width of [1440, 640, 768]) {
      await page.setViewportSize({ width, height: 1000 }); await settled(page);
      const controls = await navigation.locator(':scope > button').evaluateAll(buttons => buttons.map(button => {
        const r = button.getBoundingClientRect();
        return { name: button.getAttribute('aria-label'), visible: button.checkVisibility(), left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height };
      }));
      receipt.measurements.push({ engine: name, label: `Home-first primary navigation ${width}`, controls });
      assert.deepEqual(controls.filter(control => control.visible).map(control => control.name), expectedPrimary, 'Every primary destination is visible in Home-first order');
      for (let i = 1; i < controls.length; i++) assert.ok(controls[i].top >= controls[i - 1].bottom + 1, 'Visual primary navigation follows Home-first vertical order with separation');
      for (const control of controls) assert.ok(control.width >= 44 && control.height >= 44, `${control.name} retains a usable 44px target`);
      const more = await navigation.locator('.secondary-navigation > summary').boundingBox();
      assert.ok(more.width >= 44 && more.height >= 44 && more.y >= controls.at(-1).bottom + 1, 'More remains a separate target below Business');
      await geometry(page, name, `Home-first desktop navigation ${width}`);
      await screenshot(page, name, `home-first-navigation-${width}`);
      await go('My Listings', 'properties'); await go('Home', 'overview');
      await expect(nav('Home')).toHaveAttribute('aria-current', 'page');
      assert.equal(await navigation.locator('.secondary-navigation').evaluate(el => el.open), false, 'Returning from a primary page keeps Home outside More');
      await go('AI tools', 'creative'); await go('Home', 'overview');
      await expect(nav('Home')).toHaveAttribute('aria-current', 'page');
      assert.equal(await navigation.locator('.secondary-navigation').evaluate(el => el.open), false, 'Returning from More closes the secondary menu on Home');
    }
    await page.setViewportSize({ width: 1440, height: 1000 }); await page.evaluate(() => scrollTo(0, 0));
    check(name, 'Home leads the left navigation, stays outside More and survives route roundtrips at 1440px and resized 640/768px desktop windows');

    const spacingIssues = [];
    const requestedRoutes = process.env.STUDIO_GLASS_SPACING_ROUTES?.split(',');
    const routes = [['Home', 'overview', '.app-dashboard'], ['My Listings', 'properties', '.listing-workflow'], ['Create', 'editor', '[aria-label="Video editing workspace"]'], ['Business', 'workspace', '.business-workspace'], ['AI tools', 'creative', '.creative-workspace'], ['Content planner', 'planner', '.content-planner'], ['Media', 'library', '.library-layout']].filter(([, routeName]) => !requestedRoutes || requestedRoutes.includes(routeName));
    assert.ok(routes.length && (!requestedRoutes || routes.length === requestedRoutes.length), 'Requested spacing routes are valid');
    for (const [choice, routeName, selector] of routes) {
      for (const largeText of process.env.STUDIO_GLASS_SPACING_FOCUS ? [true] : [false, true]) for (const width of process.env.STUDIO_GLASS_SPACING_FOCUS ? [900, 1024] : largeText ? [900, 1024, 1440] : [900, 1024, 1280, 1440, 1920]) {
        // A fresh document avoids WebKit retaining offscreen button intrinsic
        // sizes after repeated viewport/font changes. Assertions remain strict.
        const sample = await context.newPage(); sample.setDefaultTimeout(15_000);
        sample.on('pageerror', error => receipt.errors.push({ engine: name, message: error.message }));
        await sample.setViewportSize({ width, height: 1000 });
        await sample.goto(`${origin}/${entry}?view=${routeName}`);
        await expect(sample.locator('.studio-glass')).toHaveAttribute('data-studio-page', routeName);
        await expect(sample.locator(selector)).toBeVisible();
        await sample.evaluate(large => { document.documentElement.style.fontSize = large ? '32px' : ''; }, largeText);
        if (routeName === 'overview') await sample.locator('.app-all-tools > summary').click();
        const more = sample.locator('.secondary-navigation > summary');
        if (await more.evaluate(el => el.parentElement.open)) await more.click();
        await sample.evaluate(() => scrollTo(0, 0));
        const label = `${routeName} spacing ${width}${largeText ? ' 200%' : ''}`;
        try { await geometry(sample, name, label); await assertTextFitsRail(sample, name, label); }
        catch (error) { spacingIssues.push({ label, issue: String(error.message) }); }
        spacingIssues.push(...(await spacingSnapshot(sample, name, label)).map(issue => ({ label, ...issue })));
        if ((!largeText && [900, 1440].includes(width)) || largeText && width === 900) await screenshot(sample, name, `spacing-${routeName}-${width}${largeText ? '-large-text' : ''}`);
        assert.deepEqual(await sample.evaluate(() => window.studioFixture.listingRows()), initialRows, `${label}: property data unchanged`);
        assert.deepEqual(await sample.evaluate(() => window.studioFixture.calls().filter(call => !['GET', 'HEAD'].includes(call.method))), [], `${label}: no API writes`);
        await sample.close();
      }
      console.log(`checked - ${name}: ${choice} spacing matrix`);
    }
    receipt.measurements.push({ engine: name, label: 'spacing matrix issues', issues: spacingIssues });
    assert.equal(spacingIssues.length, 0, `Responsive spacing issues recorded in receipt: ${spacingIssues.slice(0, 5).map(i => `${i.label}: ${i.issue}`).join('; ')}`);
    check(name, `${routes.map(([label]) => label).join(', ')} preserve semantic section/control gaps, header alignment and unclipped controls ${process.env.STUDIO_GLASS_SPACING_FOCUS ? 'at 900/1024px and 200% text' : 'across five desktop widths and three desktop widths at 200% text'}`);
    if (process.env.STUDIO_GLASS_SPACING_FOCUS) {
      assert.equal(receipt.errors.filter(e => e.engine === name).length, 0, 'No uncaught application errors');
      assert.equal(receipt.unexpectedRequests.filter(e => e.engine === name).length, 0, 'No unexpected network');
      engine.status = 'passed'; return;
    }
    await page.setViewportSize({ width: 1440, height: 1000 }); await go('Home', 'overview');

    for (const choice of ['Light', 'Dark']) {
      await appearance(choice).click(); await expect(appearance(choice)).toHaveAttribute('aria-pressed', 'true');
      await page.reload(); await expect(appearance(choice)).toHaveAttribute('aria-pressed', 'true');
      assert.equal(await page.evaluate(key => localStorage.getItem(key), appearanceKey), choice.toLowerCase());
      for (const width of [900, 1024, 1280, 1440, 1920]) {
        await page.setViewportSize({ width, height: 1000 }); await page.evaluate(() => scrollTo(0, 0));
        await geometry(page, name, `${choice} ${width}`);
        await screenshot(page, name, `${choice.toLowerCase()}-${width}`);
        if (width === 1440) await screenshot(page, name, `${choice.toLowerCase()}-${width}-full`, true);
      }
    }
    check(name, 'Light/Dark persist through reload; five desktop widths keep header, content and left navigation apart');
    await page.setViewportSize({ width: 1440, height: 1000 }); await page.evaluate(() => scrollTo(0, 0));
    await appearance('System').click();
    await page.emulateMedia({ colorScheme: 'light' }); await settled(page);
    const light = await page.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
    await page.emulateMedia({ colorScheme: 'dark' }); await settled(page);
    const dark = await page.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
    assert.notEqual(light, dark, 'System follows OS theme'); await page.reload();
    await expect(appearance('System')).toHaveAttribute('aria-pressed', 'true');
    check(name, 'System follows OS color changes and retains the saved preference');

    const toggle = page.locator('.studio-rail-toggle');
    const collapsed = await page.locator('.sidebar').boundingBox();
    await toggle.focus(); await page.keyboard.press('Enter'); await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    assert.ok((await page.locator('.sidebar').boundingBox()).width > collapsed.width + 80, 'Expanded navigation reveals readable full labels');
    await assertTextFitsRail(page, name, 'expanded rail');
    await page.keyboard.press('Enter'); await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    near((await page.locator('.sidebar').boundingBox()).width, collapsed.width, 1, 'Rail returns to compact width');
    check(name, 'keyboard expands and collapses navigation without clipping labels');

    for (const width of [900, 1440]) {
      await page.setViewportSize({ width, height: 800 });
      await page.evaluate(() => document.documentElement.style.fontSize = '32px');
      const more = page.locator('.secondary-navigation > summary');
      if (!await more.evaluate(el => el.parentElement.open)) await more.click();
      await toggle.scrollIntoViewIfNeeded(); await settled(page);
      const rail = await page.locator('.sidebar').evaluate(el => {
        const box = e => { const r = e.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }; };
        return { box: box(el), toggle: box(el.querySelector('.studio-rail-toggle')), items: [...el.querySelectorAll('.nav-item')].map(e => ({ name: e.getAttribute('aria-label'), ...box(e) })), scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight };
      });
      receipt.measurements.push({ engine: name, label: `short desktop rail ${width} 200%`, rail });
      for (const item of rail.items) assert.ok(item.bottom <= rail.toggle.top - 5, `Short rail: ${item.name} must not collide with Expand`);
      assert.ok(rail.toggle.bottom <= rail.box.bottom - 1 && rail.toggle.top >= rail.box.top, 'Short desktop rail can scroll Expand into view');
      await screenshot(page, name, `short-rail-${width}-large-text`);
      await page.evaluate(() => { document.documentElement.style.removeProperty('font-size'); document.querySelector('.sidebar').scrollTop = 0; });
    }
    check(name, '800px-high desktop rail scrolls at 200% text without navigation colliding with Expand');

    for (const width of [900, 1024, 1440]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(() => { document.documentElement.style.fontSize = '32px'; scrollTo(0, 0); });
      await geometry(page, name, `200% text ${width}`);
      await assertTextFitsRail(page, name, `200% text ${width}`);
      await screenshot(page, name, `large-text-${width}`);
      await page.evaluate(() => document.documentElement.style.removeProperty('font-size'));
    }
    check(name, '200% text remains readable without clipped navigation or horizontal page overflow');

    // The release App has its existing account/sign-in dialog and agent select;
    // this design-only release does not introduce the restaurant business chooser.
    await page.locator('.account-button').click();
    await expect(page.locator('.studio-glass')).toHaveAttribute('data-studio-page', 'workspace');
    await page.getByRole('button', { name: 'Sign out', exact: true }).click();
    for (const width of [1440, 900, 640]) {
      await page.setViewportSize({ width, height: 1000 }); await page.evaluate(() => scrollTo(0, 0));
      const trigger = page.locator('.topbar').getByRole('button', { name: 'Sign in', exact: true });
      await trigger.focus(); await page.keyboard.press('Enter');
      const dialog = page.locator('.login-dialog[role="dialog"]'); await expect(dialog).toBeVisible(); await settled(page);
      const box = await dialog.boundingBox(); assert.ok(box.x >= -1 && box.x + box.width <= width + 1 && box.y >= -1 && box.y + box.height <= 1001, 'Account dialog stays inside viewport');
      const focusTrace = [];
      for (let i = 0; i < 12; i++) {
        await page.keyboard.press('Tab');
        const focus = await dialog.evaluate(el => ({ inside: el.contains(document.activeElement), modal: el.getAttribute('aria-modal') === 'true', backgroundInert: document.querySelector('.main-shell').inert, pageFocused: document.hasFocus(), bodyActive: document.activeElement === document.body, activeLabel: document.activeElement.getAttribute('aria-label') }));
        focusTrace.push(focus);
        // WebKit's default macOS Tab behavior visits browser chrome. The actual
        // baseline App reproduces BODY + !hasFocus; background controls remain forbidden.
        assert.ok(focus.modal && focus.backgroundInert && (focus.inside || focus.bodyActive && !focus.pageFocused), 'Account dialog keeps focus away from inert background controls');
      }
      assert.ok(focusTrace.some(focus => focus.inside), 'Keyboard focus returns to the account dialog');
      receipt.measurements.push({ engine: name, label: `release account dialog keyboard ${width}`, focusTrace });
      await screenshot(page, name, `account-dialog-${width}`); await page.keyboard.press('Escape');
      await expect(dialog).not.toBeVisible(); await expect(trigger).toBeFocused();
    }
    await page.evaluate(() => window.studioFixture.switchUser('A'));
    await expect(page.locator('.account-button')).toContainText('Morgan Taylor');
    await go('Home', 'overview');
    check(name, 'existing release account dialog stays above glass, protects background focus and restores focus on Escape; synthetic identity restores after sign-out');

    await page.setViewportSize({ width: 1440, height: 1000 }); await appearance('Dark').click();
    await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce', contrast: 'more' });
    assert.equal(await page.evaluate(() => matchMedia('(prefers-contrast: more)').matches && matchMedia('(prefers-reduced-motion: reduce)').matches), true);
    await materialChrome(page, name, 'high contrast dark');
    const motion = await toggle.evaluate(el => { const s = getComputedStyle(el); return { transition: s.transitionDuration, animation: s.animationDuration }; });
    assert.ok(motion.transition.split(',').every(t => parseFloat(t) <= .01), 'Reduce Motion disables rail transitions');
    await screenshot(page, name, 'dark-high-contrast-reduced-motion');
    check(name, 'high contrast produces solid surfaces and Reduce Motion disables chrome movement');
    await page.emulateMedia({ contrast: 'no-preference', reducedMotion: 'no-preference' });
    if (name === 'chromium') {
      const cdp = await context.newCDPSession(page);
      await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }, { name: 'prefers-reduced-transparency', value: 'reduce' }] });
      assert.equal(await page.evaluate(() => matchMedia('(prefers-reduced-transparency: reduce)').matches), true);
      await materialChrome(page, name, 'reduced transparency dark');
      await screenshot(page, name, 'dark-reduced-transparency');
      await cdp.send('Emulation.setEmulatedMedia', { features: [] });
      check(name, 'Reduce Transparency explicitly removes glass blur in dark mode');
    } else receipt.limitations.push('WebKit protocol does not expose Reduce Transparency emulation; Chromium tests that media query directly, and WebKit verifies the shared opaque fallback using increased contrast.');

    await go('Create', 'editor');
    await expect(page.getByRole('region', { name: 'Video editing workspace', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Advanced desktop editor', exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Advanced desktop editor', exact: true }).click();
    await expect(page.locator('.rp-editor').first()).toBeVisible();
    receipt.measurements.push({ engine: name, label: 'solid editor', surfaces: await opaque(page, '.rp-editor:visible', 'Video editor') });
    await screenshot(page, name, 'solid-editor');
    check(name, 'actual advanced video editor remains opaque and usable behind the new shell');

    await go('Home', 'overview');
    for (const width of [640, 768]) {
      await page.setViewportSize({ width, height: 1000 }); await page.evaluate(() => scrollTo(0, 0));
      const more = page.locator('.secondary-navigation > summary');
      if (!await more.evaluate(el => el.parentElement.open)) await more.click();
      const menu = page.locator('.secondary-navigation-menu'); await expect(menu).toBeVisible();
      for (const expanded of [false, true]) {
        if (await toggle.getAttribute('aria-expanded') !== String(expanded)) await toggle.click();
        await geometry(page, name, `resized desktop ${width} ${expanded ? 'expanded' : 'compact'}`);
        await assertTextFitsRail(page, name, `resized desktop ${width} ${expanded ? 'expanded' : 'compact'}`);
        const layout = await page.locator('.sidebar').evaluate(el => {
          const box = e => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }; };
          const nav = el.querySelector('nav'), menu = el.querySelector('.secondary-navigation-menu'), summary = el.querySelector('.secondary-navigation > summary');
          return { rail: box(el), main: box(document.querySelector('#main')), direction: getComputedStyle(el).flexDirection, tracks: getComputedStyle(nav).gridTemplateColumns, menu: box(menu), menuPosition: getComputedStyle(menu).position, summary: box(summary), toggle: box(el.querySelector('.studio-rail-toggle')), items: [...menu.querySelectorAll('button')].map(box) };
        });
        receipt.measurements.push({ engine: name, label: `resized desktop inline More ${width} ${expanded ? 'expanded' : 'compact'}`, layout });
        assert.equal(layout.direction, 'column', 'Resized desktop retains a vertical sidebar');
        assert.equal(layout.tracks.trim().split(/\s+/).length, 1, 'Resized desktop retains one navigation column');
        assert.equal(layout.menuPosition, 'static', 'More tools remains inline in the desktop rail');
        // Menu padding owns the control gap; its wrapper correctly touches the summary.
        assert.ok(layout.menu.top >= layout.summary.bottom - .5 && layout.items[0].top >= layout.summary.bottom + 3.5 && layout.menu.left >= layout.rail.left && layout.menu.right <= layout.rail.right && layout.menu.right <= layout.main.left - 7, 'More tools controls stay separated below the summary and inside the left rail without covering content');
        assert.ok(layout.items[1].top >= layout.items[0].bottom + 1, 'Secondary tools remain vertically ordered');
        await toggle.scrollIntoViewIfNeeded(); await expect(toggle).toBeVisible();
        await screenshot(page, name, `resized-desktop-${width}-${expanded ? 'expanded' : 'compact'}-more`);
      }
      await toggle.click(); await expect(toggle).toHaveAttribute('aria-expanded', 'false');
      await more.click();
      await page.locator('.workspace-footer').scrollIntoViewIfNeeded();
      await page.evaluate(() => scrollTo(0, document.documentElement.scrollHeight)); await settled(page);
      const footer = await page.locator('.workspace-footer').boundingBox(), rail = await page.locator('.sidebar').boundingBox();
      assert.ok(footer.x >= rail.x + rail.width + 7 && footer.y + footer.height <= 1001, 'Page end stays visible beside the left rail without a bottom overlay');
    }
    check(name, '640/768px resized desktop windows retain expandable left navigation, inline More tools and reachable page content without a bottom dock');

    assert.deepEqual(await page.evaluate(() => window.studioFixture.listingRows()), initialRows, 'Presentation checks never change property data');
    const writes = await page.evaluate(() => window.studioFixture.calls().filter(call => !['GET', 'HEAD'].includes(call.method)));
    assert.deepEqual(writes, [], 'Appearance/navigation/dialog checks must not write through API');
    assert.equal(receipt.errors.filter(e => e.engine === name).length, 0, 'No uncaught application errors');
    assert.equal(receipt.unexpectedRequests.filter(e => e.engine === name).length, 0, 'No external or non-read network requests');
    engine.status = 'passed';
  } catch (error) {
    engine.status = 'failed'; engine.failure = String(error.stack ?? error);
    console.error(`failed - ${name}: ${error.message}`);
    await page.screenshot({ path: join(artifacts, `${name}-failure.png`), fullPage: true }).catch(() => {});
    await writeFile(join(artifacts, `${name}-failure.txt`), await page.locator('body').innerText().catch(() => ''));
  } finally { await browser.close(); }
}

try {
  await build(previewBuildOptions(root, dist, join(root, entry)));
  server = createServer(async (req, res) => {
    const path = resolve(dist, `.${new URL(req.url, 'http://localhost').pathname}`);
    if (!path.startsWith(`${dist}/`) || !['GET', 'HEAD'].includes(req.method)) return res.writeHead(400).end();
    try { res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.png': 'image/png' })[extname(path)] ?? 'application/octet-stream'); if (extname(path) === '.html') res.setHeader('Content-Security-Policy', previewCsp()); res.end(await readFile(path)); }
    catch { res.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  assert.ok(receipt.requestedEngines.length && receipt.requestedEngines.every(name => ['chromium', 'webkit'].includes(name)), 'Requested browser engines are valid');
  if (receipt.requestedEngines.includes('chromium')) await runEngine('chromium', chromium, process.env.STUDIO_BROWSER_EXECUTABLE ?? process.env.PW_CHROMIUM, origin);
  if (receipt.requestedEngines.includes('webkit')) await runEngine('webkit', webkit, process.env.STUDIO_WEBKIT_EXECUTABLE, origin);
  receipt.status = receipt.engines.every(e => e.status === 'passed') ? 'passed' : 'failed';
} catch (error) { receipt.status = 'failed'; receipt.failure = String(error.stack ?? error); }
finally {
  if (server) await new Promise(done => server.close(done));
  await writeFile(join(artifacts, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({ status: receipt.status, engines: receipt.engines, checks: receipt.checks.length, artifacts }, null, 2));
  if (receipt.status !== 'passed') process.exitCode = 1;
}
