// The browser is a separate compilation target. Its complete import graph must
// cross into the Worker as inert bytes, never as functions reconstructed with
// Function.toString(). Worker minification can then change no browser bindings.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const GENERATED_TS = 'src/spatial-browser.generated.ts';
export const GENERATED_JSON = 'src/spatial-browser.generated.json';
const ENTRY = 'src/browser/spatial-viewer.js';
const BUILDER = 'scripts/build-spatial-browser.mjs';
const ESBUILD_VERSION = '0.28.1';
const MAX_SOURCE_BYTES = 512000;
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const json = value => JSON.stringify(value, null, 2) + '\n';

function readBounded(path, max = 2 * 1024 * 1024) {
  const info = statSync(path);
  assert(info.isFile() && info.size <= max, 'Browser build input is not a bounded file');
  const data = readFileSync(path);
  assert(data.length <= max, 'Browser build input grew beyond its limit');
  return data;
}

function localPath(root, path) {
  const resolved = realpathSync(path);
  const rel = relative(root, resolved);
  assert(rel && !isAbsolute(rel) && rel !== '..' && !rel.startsWith('..' + sep),
    'Browser input escapes its package');
  return rel.split(sep).join('/');
}

/** Pure build result: no generated file is written. Gates can independently
 * vary browser minification/name retention while exercising the same imports.
 * root always means the tour-host package root, not the invocation directory. */
export async function buildSpatialBrowser({ root = ROOT, minify = false, keepNames = false } = {}) {
  assert.equal(typeof minify, 'boolean', 'minify must be boolean');
  assert.equal(typeof keepNames, 'boolean', 'keepNames must be boolean');
  root = realpathSync(resolve(root));
  assert.equal(esbuild.version, ESBUILD_VERSION, 'Unexpected esbuild runtime version');
  const packageBytes = readBounded(join(root, 'package.json'));
  const lockBytes = readBounded(join(root, 'package-lock.json'));
  const builderBytes = readBounded(join(root, BUILDER));
  // A caller must not run one builder while attaching another builder's hash.
  assert.equal(sha(builderBytes), sha(readBounded(fileURLToPath(import.meta.url))),
    'Requested package contains a different browser builder');
  const pkg = JSON.parse(packageBytes), lock = JSON.parse(lockBytes);
  assert.equal(pkg.devDependencies?.esbuild, ESBUILD_VERSION, 'esbuild must be an exact direct devDependency');
  assert.equal(lock.packages?.['']?.devDependencies?.esbuild, ESBUILD_VERSION, 'Root lockfile esbuild pin drift');
  assert.equal(lock.packages?.['node_modules/esbuild']?.version, ESBUILD_VERSION, 'Resolved esbuild lock drift');

  const options = {
    entryPoints: [ENTRY], bundle: true, platform: 'browser', format: 'esm',
    target: ['es2022'], minify, keepNames, splitting: false, sourcemap: false,
    legalComments: 'none', charset: 'utf8', treeShaking: true,
    // Do not inherit an unrelated parent tsconfig or implicit NODE_ENV value.
    tsconfigRaw: { compilerOptions: {} }, define: { 'process.env.NODE_ENV': '"production"' },
    outfile: 'spatial-viewer.js',
  };
  const inputs = new Map();
  let inputBytes = 0;
  const result = await esbuild.build({
    ...options, absWorkingDir: root, write: false, metafile: true, logLevel: 'silent',
    plugins: [{ name: 'record-exact-browser-inputs', setup(build) {
      build.onLoad({ filter: /.*/, namespace: 'file' }, args => {
        const path = localPath(root, args.path);
        assert(path.startsWith('src/') && path !== GENERATED_TS && path !== GENERATED_JSON,
          'Browser imports must be ordinary source files, not generated output or server dependencies');
        const loader = { '.js': 'js', '.mjs': 'js', '.ts': 'ts', '.json': 'json' }[extname(path)];
        assert(loader, 'Unsupported browser import type');
        const contents = readBounded(args.path, MAX_SOURCE_BYTES);
        inputBytes += contents.length;
        assert(inputBytes <= 2 * 1024 * 1024 && inputs.size < 128, 'Browser import graph exceeds bound');
        inputs.set(path, { path, bytes: contents.length, sha256: sha(contents) });
        return { contents: new TextDecoder('utf-8', { fatal: true }).decode(contents), loader,
          resolveDir: dirname(args.path) };
      });
    } }],
  });
  assert.equal(result.warnings.length, 0, 'Browser build warnings require review');
  assert.equal(result.outputFiles?.length, 1, 'Browser must emit one self-contained ESM file');
  const source = result.outputFiles[0].text;
  assert(Buffer.byteLength(source) > 0 && Buffer.byteLength(source) <= MAX_SOURCE_BYTES, 'Browser output exceeds bound');
  const output = Object.values(result.metafile.outputs);
  assert.equal(output.length, 1, 'Unexpected browser output graph');
  assert.equal(output[0].imports.length, 0, 'Browser bundle must have no unresolved imports');
  for (const name of ['mountSpatial', 'decodeSpatialManifest', 'inspectSpatialSog']) {
    assert(output[0].exports.includes(name), 'Missing browser ESM export: ' + name);
  }
  assert(inputs.has(ENTRY), 'Actual browser entry did not compile');
  assert.equal(Object.keys(result.metafile.inputs).length, inputs.size, 'Unrecorded browser input');
  // Detect source changes during compilation; metadata describes the bytes the
  // compiler actually read, not a post-build guess about what it might have read.
  for (const input of inputs.values()) {
    assert.equal(sha(readBounded(join(root, input.path), MAX_SOURCE_BYTES)), input.sha256,
      'Browser source changed while building: ' + input.path);
  }
  for (const [path, bytes] of [['package.json', packageBytes], ['package-lock.json', lockBytes], [BUILDER, builderBytes]]) {
    assert.equal(sha(readBounded(join(root, path))), sha(bytes), 'Browser build configuration changed: ' + path);
  }
  const metadata = {
    schema_version: 1, entry: ENTRY, tool: { name: 'esbuild', version: esbuild.version },
    options, package_sha256: sha(packageBytes), lock_sha256: sha(lockBytes),
    build_script_sha256: sha(builderBytes),
    inputs: [...inputs.values()].sort((a, b) => a.path.localeCompare(b.path, 'en')),
    browser_bytes: Buffer.byteLength(source), browser_sha256: sha(source),
  };
  const generatedTypeScript = '// Generated by scripts/build-spatial-browser.mjs --write. Do not edit.\n' +
    '// Browser ESM is deliberately inert here: Wrangler must never recompile its bindings.\n' +
    'export const SPATIAL_BROWSER_SOURCE = ' + JSON.stringify(source) + ';\n';
  return { source, metafile: result.metafile, metadata, generatedTypeScript, generatedMetadata: json(metadata) };
}

/** Check-only by design. A stale committed artifact must stop direct Wrangler
 * invocations too, not quietly become a different unreviewed release artifact. */
export async function checkSpatialBrowser({ root = ROOT } = {}) {
  root = realpathSync(resolve(root));
  const built = await buildSpatialBrowser({ root });
  for (const [path, expected] of [[GENERATED_TS, built.generatedTypeScript], [GENERATED_JSON, built.generatedMetadata]]) {
    let actual;
    try { actual = readBounded(join(root, path)); }
    catch (error) {
      if (error.code === 'ENOENT') throw new Error('Missing generated browser artifact: ' + path + '; run npm run build:spatial:browser');
      throw error;
    }
    assert(actual.equals(Buffer.from(expected)),
      'Stale generated browser artifact: ' + path + '; run npm run build:spatial:browser');
  }
  return built;
}

async function main(args) {
  assert(['--write', '--check'].includes(args[0]), 'Use --write or --check');
  assert(args.length === 1 || (args.length === 3 && args[1] === '--root'), 'Unexpected browser build arguments');
  const root = args.length === 3 ? resolve(args[2]) : ROOT;
  const built = args[0] === '--check' ? await checkSpatialBrowser({ root }) : await buildSpatialBrowser({ root });
  if (args[0] === '--write') {
    // If interrupted between these files, the next check rejects the pair.
    writeFileSync(join(root, GENERATED_TS), built.generatedTypeScript);
    writeFileSync(join(root, GENERATED_JSON), built.generatedMetadata);
  }
  console.log(JSON.stringify({ mode: args[0], status: 'passed', browser_sha256: built.metadata.browser_sha256,
    browser_bytes: built.metadata.browser_bytes, input_count: built.metadata.inputs.length }));
}

// Node canonicalizes import.meta.url, but argv can retain a symlink such as
// macOS /tmp -> /private/tmp. Comparing unresolved paths can return exit 0
// without ever running --write or --check, so compare real files instead.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
