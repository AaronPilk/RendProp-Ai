import assert from 'node:assert/strict';
import test from 'node:test';
import { RenderBenchmark, assertSogEnvelope } from './benchmark.mjs';

const start = (b) => b.start({ ready: true, visible: true, deviceLabel: 'Synthetic clock test, not a phone' }, 0);
const draw = (b, t, onscreenDraws = 1) => b.rendered(t, { visible: true, onscreenDraws, splatCount: 10 });

if (process.argv.includes('--negative-control')) {
  const b = new RenderBenchmark({ warmupMs: 0, sampleMs: 100 });
  start(b);
  for (let i = 0; i <= 1000; i += 10) draw(b, i, 0);
  // Deliberately wrong claim: the process MUST exit nonzero. This verifies the
  // harness cannot report success merely because an empty RAF loop is fast.
  assert.equal(b.result?.valid, true, 'NEGATIVE CONTROL: empty RAF must never produce valid FPS');
}

test('empty RAF callbacks and unloaded scenes cannot create FPS', () => {
  const b = new RenderBenchmark({ warmupMs: 0, sampleMs: 100 });
  assert.throws(() => b.start({ ready: false, visible: true, deviceLabel: 'x' }, 0));
  start(b);
  for (let i = 0; i <= 1000; i += 10) draw(b, i, 0);
  assert.equal(b.result, null);
  b.tick(11000, true);
  assert.equal(b.result.valid, false);
  assert.equal(b.result.fps, null);
});

test('warmup is excluded; rate uses frame intervals rather than overcounting first frame', () => {
  const b = new RenderBenchmark({ warmupMs: 100, sampleMs: 1000 });
  start(b);
  for (let i = 0; i <= 1100; i += 20) draw(b, i);
  assert.equal(b.result.fps, 50);
  assert.equal(b.result.elapsedMs, 1000);
  assert.equal(b.result.renderedFrames, 51);
  assert.equal(b.result.p95FrameIntervalMs, 20);
});

test('missing draws lower throughput instead of inflating FPS', () => {
  const b = new RenderBenchmark({ warmupMs: 0, sampleMs: 100 });
  start(b);
  draw(b, 0); draw(b, 10); draw(b, 20, 0); draw(b, 100);
  assert.equal(b.result.fps, 20);
  assert.equal(b.result.maxFrameIntervalMs, 90);
});

test('hidden page invalidates instead of blending foreground and background', () => {
  const b = new RenderBenchmark();
  start(b); draw(b, 0); b.tick(10, false);
  assert.equal(b.result.valid, false);
  assert.equal(b.result.fps, null);
});

test('context loss and input changes can invalidate a run', () => {
  const b = new RenderBenchmark();
  start(b); b.invalidate('Graphics context lost');
  assert.equal(b.result.reason, 'Graphics context lost');
});

test('nonfinite durations and clocks cannot create a permanent or fabricated measurement', () => {
  for (const invalid of [Infinity, -Infinity, NaN]) {
    assert.throws(() => new RenderBenchmark({ warmupMs: invalid }));
    assert.throws(() => new RenderBenchmark({ sampleMs: invalid }));
    const b = new RenderBenchmark();
    assert.throws(() => b.start({ ready: true, visible: true, deviceLabel: 'x' }, invalid));
    start(b); b.tick(invalid, true);
    assert.equal(b.result.valid, false);
    assert.equal(b.result.fps, null);
  }
  const b = new RenderBenchmark(); start(b); draw(b, -1);
  assert.equal(b.result.valid, false);
});

test('invalid input is refused; ZIP signature alone does not validate room data', () => {
  assert.throws(() => assertSogEnvelope('room.ply', new ArrayBuffer(32)));
  assert.throws(() => assertSogEnvelope('room.sog', new ArrayBuffer(32)));
  const zip = new Uint8Array(32); zip.set([0x50, 0x4b, 3, 4]);
  assert.doesNotThrow(() => assertSogEnvelope('room.sog', zip.buffer));
});
