// check-bundle.mjs — the served /spatial-viewer.js must work as built, not as written.
//
// spatialModule() ships decodeSpatialManifest and inspectSpatialSog to browsers
// as Function.toString() text. The other gates transpile src/ with TypeScript,
// so they never see what wrangler's esbuild does to those bodies: with keepNames
// on (wrangler's default) every inner arrow became `__name(() => {...}, "fail")`,
// the served module never defined `__name`, and the first decoder call in every
// browser threw ReferenceError while CI stayed green.
//
// This gate builds the Worker as `npx wrangler deploy --dry-run` does, serves
// /spatial-viewer.js through the built default export's fetch(), and evaluates
// that text as a real ES module before calling both decoders. It then rebuilds
// with keep_names = true (the setting that shipped the bug), strips the shim
// from that module and proves the same checks fail. Offline: the dry run needs
// no credentials, and fetch is disabled while the module is served.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { fixture, sogFiles, storedZip } from './check-spatial.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CACHE = join(ROOT, 'node_modules', '.cache', 'spatial-bundle-check');
// Must match SPATIAL_MODULE_SHIM in src/spatial.ts; the served text is checked for it.
const SHIM = 'const __name = (fn) => fn;';
const wrangler = join(dirname(createRequire(import.meta.url).resolve('wrangler/package.json')), 'bin', 'wrangler.js');
let assertions = 0;
const check = (condition, message) => { assertions++; assert.ok(condition, message); };

/** `npx wrangler deploy --dry-run --outdir <out>` from the tour-host dir, optionally
 * with another config. Returns the built bundle as an unambiguous .mjs path. */
function bundle(label, configPath) {
  const out = join(CACHE, label);
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  // Paths are absolute: wrangler resolves relative ones against the config's directory.
  const args = [wrangler, 'deploy', '--dry-run', '--outdir', out, ...(configPath ? ['--config', configPath] : [])];
  const run = spawnSync(process.execPath, args, { cwd: ROOT, encoding: 'utf8', timeout: 180000, env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  if (run.status !== 0) {
    process.stderr.write(`${run.stdout || ''}${run.stderr || ''}`);
    throw new Error(`wrangler deploy --dry-run (${label}) exited ${run.status === null ? run.signal : run.status}`);
  }
  const built = join(out, 'index.js');
  check(existsSync(built), `dry run wrote ${built}`);
  const esm = join(out, 'index.mjs');
  copyFileSync(built, esm);
  return esm;
}

/** The exact bytes production serves: the built Worker's fetch() on the real route. */
async function serve(bundlePath) {
  const { default: worker } = await import(pathToFileURL(bundlePath).href);
  check(typeof worker?.fetch === 'function', 'built bundle default-exports a fetch handler');
  const env = { SUPABASE_FUNCTIONS_URL: 'https://bundle-check.invalid/functions/v1', SUPABASE_ANON_KEY: 'synthetic-public-key', TOUR_CACHE_TTL: '0', TURNSTILE_SITE_KEY: '' };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('serving /spatial-viewer.js must not make a network request'); };
  try {
    const response = await worker.fetch(new Request('https://rendprop.com/spatial-viewer.js'), env, { waitUntil() {}, passThroughOnException() {} });
    check(response.status === 200, 'built Worker serves /spatial-viewer.js');
    check(response.headers.get('Content-Type') === 'text/javascript; charset=utf-8', 'served as a JavaScript module');
    check(response.headers.get('Cache-Control') === 'no-store', 'module is not cached');
    const text = await response.text();
    check(text.includes('export function mountSpatial'), 'served text is the spatial runtime');
    return text;
  } finally { globalThis.fetch = originalFetch; }
}

/** Every `__name(` call in the served text needs a `__name` defined before it. */
function staticCheck(text) {
  const call = /__name\s*\(/.exec(text);
  if (!call) return 0;
  const definition = /\b(?:const|let|var)\s+__name\b|\bfunction\s+__name\b/.exec(text);
  assert.ok(definition && definition.index < call.index,
    `served module calls __name at offset ${call.index} without defining it first: keepNames output shipped without the shim`);
  return text.match(/__name\s*\(/g).length;
}

/** Evaluate the served text as an ES module and exercise both decoders. The
 * appended export line only exposes the module's existing top-level bindings. */
async function dynamicCheck(text) {
  const mod = await import('data:text/javascript;charset=utf-8,' + encodeURIComponent(text + '\nexport { decodeSpatialManifest, inspectSpatialSog };'));
  assert.equal(typeof mod.mountSpatial, 'function', 'mountSpatial exported');
  assert.equal(mod.decodeSpatialManifest(fixture).rooms[0].id, 'kitchen', 'decodeSpatialManifest accepts the fixture');
  assert.throws(() => mod.decodeSpatialManifest({}), { message: 'Invalid spatial scene manifest' }, 'invalid manifest surfaces the decoder error');
  assert.equal(mod.inspectSpatialSog(storedZip(sogFiles()), 2048).texturePixels, 10240, 'inspectSpatialSog accepts the bounded SOG');
  assert.throws(() => mod.inspectSpatialSog(new Uint8Array(21), 2048), { message: 'Room package is not a supported bounded SOG' }, 'short SOG surfaces the decoder error');
}

async function verify(text) { staticCheck(text); await dynamicCheck(text); }

// The static check must itself tell a defined helper from an undefined one.
assertions++; assert.equal(staticCheck('const x = 1;'), 0);
assertions++; assert.equal(staticCheck(SHIM + '\nconst f = __name(() => 1, "f");'), 1);
assertions++; assert.throws(() => staticCheck('const f = __name(() => 1, "f");'), /without defining it first/);
assertions++; assert.throws(() => staticCheck('const f = __name(() => 1, "f");\n' + SHIM), /without defining it first/);

// 1. The real configuration: what `wrangler deploy` ships. On the bundle that
// shipped the bug this fails inside verify() with the offset of the first
// undefined __name call; the two checks after it keep both guards in place.
const served = await serve(bundle('real'));
await verify(served);
assertions++;
check(served.startsWith(SHIM + '\n'), 'served module starts with the __name shim (src/spatial.ts SPATIAL_MODULE_SHIM)');
check(staticCheck(served) === 0, 'wrangler.toml keep_names = false leaves no __name calls in the served module');

// 2. Negative control on the toolchain default. keep_names = false leaves the
// shim nothing to do, so removing it from the real module proves nothing; the
// bundle has to be rebuilt the way it was when the bug shipped.
const config = readFileSync(join(ROOT, 'wrangler.toml'), 'utf8');
const compatibilityDate = /^compatibility_date\s*=\s*"([^"]+)"/m.exec(config)?.[1];
check(compatibilityDate, 'compatibility_date read from wrangler.toml');
const probeConfig = join(CACHE, 'keep-names.toml');
mkdirSync(CACHE, { recursive: true });
writeFileSync(probeConfig, [
  '# Written by scripts/check-bundle.mjs: the same entry with keep_names on, the',
  '# wrangler default that shipped the __name bug. Not a deployable config.',
  'name = "rendprop-tour-host-keep-names-probe"',
  `main = ${JSON.stringify(join(ROOT, 'src', 'index.ts'))}`,
  `compatibility_date = ${JSON.stringify(compatibilityDate)}`,
  'workers_dev = false',
  'keep_names = true',
  '',
].join('\n'));
const probe = await serve(bundle('keep-names', probeConfig));
check(probe.startsWith(SHIM + '\n'), 'keep_names build also starts with the shim');
const wrapped = staticCheck(probe);
check(wrapped > 0, `keep_names = true still injects __name into Function.toString() output (${wrapped} calls); if this stops, rework this negative control`);
await verify(probe);
assertions++;
check(probe.includes('/* @__PURE__ */ __name('), 'probe reproduces the exact esbuild keepNames wrapper');

// Shim removed: exactly the module rendprop.com served, and the gate must fail on it.
const stripped = probe.replace(SHIM + '\n', '');
check(stripped !== probe && !stripped.includes(SHIM), 'shim stripped from the keep_names module');
assertions++; assert.throws(() => staticCheck(stripped), /without defining it first/, 'static check fails without the shim');
assertions++; await assert.rejects(dynamicCheck(stripped), { name: 'ReferenceError', message: '__name is not defined' }, 'decoder call fails without the shim');
assertions++; await assert.rejects(verify(stripped), 'gate fails on the shim-less keep_names module');

console.log(`Bundle gate: ${assertions} assertions, 0 skipped; actual wrangler dry-run bundle (real config + keep_names probe), served through the built Worker's fetch and evaluated as an ES module; negative control failed as required. No deploy, no network.`);
