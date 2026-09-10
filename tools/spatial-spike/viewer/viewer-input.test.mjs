import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

// Exercise the production loader unchanged, with only the browser startup
// removed. Engine stubs prove ordering/provenance, NOT SOG decode or WebGL.
async function loader({ splatCount = 2048 } = {}) {
  let source = await readFile(new URL('./viewer.mjs', import.meta.url), 'utf8');
  const globals = { performance };
  const imports = [...source.matchAll(/^import \{ ([^}]+) \} from '([^']+)';$/gm)];
  assert.ok(imports.length > 0, 'actual production imports must be loaded');
  for (const match of imports) {
    const dependency = await import(new URL(match[2], import.meta.url));
    for (const name of match[1].split(',').map((value) => value.trim())) {
      assert.ok(name in dependency, `missing production dependency: ${name}`);
      globals[name] = dependency[name];
    }
    source = source.replace(match[0], '');
  }
  const startup = /^main\(\)\.catch\(.*\);$/m;
  assert.ok(startup.test(source), 'must remove exactly the browser startup');
  source = source.replace(startup, '');
  const elements = new Map();
  globals.document = { getElementById(id) {
    if (!elements.has(id)) elements.set(id, { disabled: false, textContent: '' });
    return elements.get(id);
  } };
  const counters = { entities: 0, destroyed: 0, unloaded: 0, removed: 0 };
  globals.pc = {
    Asset: class {
      constructor() {
        this.callbacks = new Map();
        this.resource = { numSplats: splatCount, aabb: { center: { x: 0, y: 0, z: 0 }, halfExtents: { length: () => 1 } } };
      }
      once(name, callback) { this.callbacks.set(name, callback); }
      unload() { counters.unloaded++; }
    },
    Entity: class {
      constructor() { counters.entities++; }
      addComponent() {}
      destroy() { counters.destroyed++; }
    }
  };
  globals.fakeApp = {
    assets: { add() {}, remove() { counters.removed++; }, load(asset) { asset.callbacks.get('load')(); } },
    root: { addChild() {} }
  };
  globals.fakeCamera = { camera: {}, setPosition() {}, lookAt() {}, getEulerAngles: () => ({ x: 0, y: 0 }) };
  const context = vm.createContext(globals);
  vm.runInContext(`${source}\napp = fakeApp; camera = fakeCamera; globalThis.testLoader = { loadFile, state: () => ({ loaded, loading }) };`, context);
  return { ...context.testLoader, counters, elements };
}

function input(name = 'local-artifact.sog', declaredBytes = 32, actualBytes = 32) {
  let reads = 0;
  const bytes = new Uint8Array(actualBytes); bytes.set([0x50, 0x4b, 3, 4]);
  return { name, size: declaredBytes, arrayBuffer: async () => { reads++; return bytes.buffer; }, reads: () => reads };
}

test('actual loader still admits a small SOG envelope through the stubbed engine', async () => {
  const harness = await loader(); const file = input();
  await harness.loadFile(file);
  assert.equal(file.reads(), 1);
  assert.equal(harness.counters.entities, 1);
  assert.equal(harness.state().loaded.splatCount, 2048);
  assert.equal(harness.state().loading, false);
});

test('actual loader rejects declared inputs above 64 MiB before arrayBuffer', async () => {
  const harness = await loader(); const file = input('large.sog', 64 * 1024 * 1024 + 1);
  await harness.loadFile(file);
  assert.equal(file.reads(), 0, 'oversize input must not be read');
  assert.equal(harness.state().loaded, null);
  assert.equal(harness.counters.entities, 0);
  assert.equal(harness.state().loading, false);
});

test('actual loader rejects an unsupported extension before arrayBuffer', async () => {
  const harness = await loader(); const file = input('artifact.ply');
  await harness.loadFile(file);
  assert.equal(file.reads(), 0, 'unsupported input must not be read');
  assert.equal(harness.state().loaded, null);
});

test('actual loader refuses decoded counts above 500,000 before creating an entity', async () => {
  const harness = await loader({ splatCount: 500001 });
  await harness.loadFile(input());
  assert.equal(harness.counters.entities, 0, 'over-cap resource must not become a render entity');
  assert.equal(harness.state().loaded, null);
  assert.equal(harness.counters.unloaded, 1, 'decoded rejected asset must be released');
  assert.equal(harness.counters.removed, 1);
});

test('actual local file picker recognizes reserved synthetic names without fixture mode', async () => {
  const harness = await loader();
  await harness.loadFile(input('SYNTHETIC-NOT-A-ROOM.sog'));
  assert.equal(harness.state().loaded.provenance, 'synthetic');
  assert.equal(harness.state().loaded.synthetic, true);
  assert.equal(harness.state().loaded.realRoomVerified, false);
});

test('ordinary local filenames never assert real-room provenance', async () => {
  const harness = await loader();
  await harness.loadFile(input());
  assert.equal(harness.state().loaded.provenance, 'unknown');
  assert.equal(harness.state().loaded.synthetic, null);
  assert.equal(harness.state().loaded.realRoomVerified, false);
  assert.match(harness.elements.get('status').textContent, /UNVERIFIED/);
});

test('actual loader rejects declared/observed byte mismatch before engine use', async () => {
  const harness = await loader();
  await harness.loadFile(input('mismatch.sog', 31, 32));
  assert.equal(harness.counters.entities, 0);
  assert.equal(harness.state().loaded, null);
});
