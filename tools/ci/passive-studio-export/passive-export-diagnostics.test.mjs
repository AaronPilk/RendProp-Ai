// Closed controls for the diagnostic observer itself. No browser/media launch.
import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import {readFile} from "node:fs/promises";
import {stripTypeScriptTypes} from "node:module";
import {installPassiveExportObserver} from "./passive-export-observer.mjs";
import {instrumentExportSource, instrumentCadenceSource} from "./passive-export-plugin.mjs";

const manifest = JSON.parse(await readFile(new URL('./diagnostic-copy-manifest.json', import.meta.url), 'utf8'));
const sourceRoot = manifest.studioRoot + '/';
const shippingExport = await readFile(sourceRoot + 'src/editor/export.ts', 'utf8');
const shippingCadence = await readFile(sourceRoot + 'src/editor/mp4-cadence.ts', 'utf8');

function fixture() {
  let milliseconds = 1000;
  const native = {calls: [], result: undefined, error: undefined};
  class Track {
    requestFrame(...args) {
      native.calls.push({receiver: this, args});
      if (native.error !== undefined) throw native.error;
      return native.result;
    }
  }
  const global = {structuredClone, CanvasCaptureMediaStreamTrack: Track,
    performance: {timeOrigin: 123456, now: () => ++milliseconds}};
  global.window = global;
  const context = vm.createContext(global);
  vm.runInContext(`(${installPassiveExportObserver.toString()})()`, context);
  const transformed = instrumentExportSource(shippingExport);
  const helperAt = transformed.indexOf('// Injected into a diagnostic build only;');
  assert(helperAt > 0);
  vm.runInContext(stripTypeScriptTypes(transformed.slice(helperAt)), context);
  return {context, observer: global.rendpropPassiveExportDiagnostic, native,
    track: new Track(), helper: context.rpDiagnosticRequestFrame};
}

test('actual diagnostic helper/hook preserve native receiver, args, return and thrown identity', () => {
  const f = fixture();
  assert.equal(f.observer.snapshot().nativeHook.installed, true);
  f.observer.beginExport(900);
  const metadata = {phase: 'paint', clipIndex: 1, localSeconds: .25, timelineSeconds: .75};
  const token = {};
  f.native.result = token;
  assert.equal(f.helper(metadata, () => f.track.requestFrame('native-argument')), token);
  assert.equal(f.native.calls.length, 1);
  assert.equal(f.native.calls[0].receiver, f.track);
  assert.deepEqual(f.native.calls[0].args, ['native-argument']);
  const sentinel = new Error('native sentinel');
  f.native.error = sentinel;
  assert.throws(() => f.helper(metadata, () => f.track.requestFrame()), error => error === sentinel);
  const rows = f.observer.snapshot().sessions[0].requests;
  assert.equal(rows.length, 2);
  assert.equal(rows[0].clipIndex, 1);
  assert.equal(rows[0].localSeconds, .25);
  assert.equal(rows[0].timelineSeconds, .75);
  assert.equal(rows[0].threw, false);
  assert.equal(rows[1].threw, true);
  assert.equal(rows[1].errorName, 'Error');
});

test('metadata-only helper forwards optional absence and never invents a native call', () => {
  const f = fixture();
  f.observer.beginExport(900);
  assert.equal(f.helper({phase: 'initial'}, () => undefined), undefined);
  assert.equal(f.native.calls.length, 0);
  assert.equal(f.observer.snapshot().sessions[0].requestCount, 0);
});

test('observer failures do not replace native results or exceptions', () => {
  const f = fixture();
  f.observer.beginExport(900);
  f.observer.beginRequest = () => {throw new Error('observer begin failed');};
  f.observer.beforeNativeRequest = () => {throw new Error('observer before failed');};
  f.observer.afterNativeRequest = () => {throw new Error('observer after failed');};
  f.observer.endRequest = () => {throw new Error('observer end failed');};
  f.native.result = 42;
  assert.equal(f.helper({}, () => f.track.requestFrame()), 42);
  const sentinel = {};
  f.native.error = sentinel;
  assert.throws(() => f.helper({}, () => f.track.requestFrame()), error => error === sentinel);
  assert.equal(f.native.calls.length, 2);
});

test('request and session retention are bounded without skipping native calls', () => {
  const f = fixture();
  for (let session = 0; session < 5; session++) {
    f.observer.beginExport(900 + session);
    for (let index = 0; index < 125; index++) f.helper({phase: 'paint', localSeconds: index / 30}, () => f.track.requestFrame());
  }
  const result = f.observer.snapshot();
  assert.equal(f.native.calls.length, 625);
  assert.equal(result.sessions.length, 4);
  assert(result.sessions.every(row => row.requestCount === 125 && row.requests.length === 120));
});

test('encoded observer keeps first16 and bounded refusal neighborhood without frame bytes', () => {
  const f = fixture();
  f.observer.beginExport(900);
  const frames = Array.from({length: 100}, (_, index) => ({start: index / 30, end: (index + 1) / 30}));
  f.observer.encodedSummary(frames.slice(0, 16), 100, 30000);
  f.observer.encodedRefusal(20, frames.slice(16, 25), 16, 'sample-duration');
  const result = f.observer.snapshot().sessions[0].encoded;
  assert.equal(result.first16.length, 16);
  assert.equal(result.refusal.neighborhood.length, 9);
  assert.equal(result.refusal.neighborhood[0].ordinal, 16);
  assert.equal(result.refusal.frameIndex, 20);
  assert.equal(result.frameCount, 100);
});

test('transforms require exact shipping anchors and retain original strict guard expressions', () => {
  const result = instrumentCadenceSource(shippingCadence);
  for (const guard of [
    'if (duration > MAX_ENCODED_GAP_SECONDS)',
    'if (startGap > MAX_ENCODED_GAP_SECONDS)',
    'index - windowStart + 1 < MIN_FRAMES_PER_WINDOW)',
    'const MAX_ENCODED_GAP_SECONDS = .15;',
    'const MIN_FRAMES_PER_WINDOW = 11;',
  ]) assert(result.includes(guard), guard);
  for (const statement of shippingCadence.matchAll(/throw skippedFrames\([\s\S]*?\);/g)) assert(result.includes(statement[0]));
  assert.throws(() => instrumentExportSource(shippingExport.replace('track?.requestFrame?.();', 'track?.requestFrame?.(1);')), /Diagnostic anchor changed/);
  assert.throws(() => instrumentCadenceSource(shippingCadence.replace('frames.sort((a, b) => a.start - b.start);', '')), /Diagnostic anchor changed/);
});
