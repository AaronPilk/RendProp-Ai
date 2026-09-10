import assert from 'node:assert/strict';
import test from 'node:test';
import { assertSogInput, readSogInput, assertDecodedSplatCount, localProvenance, readFixtureResponse, MAX_SOG_BYTES, MAX_SPLAT_COUNT } from './input-policy.mjs';

function envelope() { const bytes = new Uint8Array(32); bytes.set([0x50, 0x4b, 3, 4]); return bytes; }

test('encoded byte admission is inclusive and rejects invalid numeric sizes before read', async () => {
  for (const size of [22, MAX_SOG_BYTES]) assert.doesNotThrow(() => assertSogInput('room.SOG', size));
  for (const size of [0, 21, -1, 22.5, NaN, Infinity, -Infinity, MAX_SOG_BYTES + 1, '32', null, undefined]) {
    let reads = 0;
    await assert.rejects(readSogInput({ name: 'room.sog', size, arrayBuffer() { reads++; throw new Error('must not read'); } }));
    assert.equal(reads, 0, `pre-read rejection for ${String(size)}`);
  }
});

test('observed oversized bytes and malformed envelopes cannot bypass metadata checks', async () => {
  // Metadata-only stand-in avoids allocating a huge buffer. The cap must reject
  // it before assertSogEnvelope attempts to inspect any byte content.
  await assert.rejects(readSogInput({ name: 'room.sog', size: 32, arrayBuffer: async () => ({ byteLength: MAX_SOG_BYTES + 1 }) }), /64 MiB/);
  await assert.rejects(readSogInput({ name: 'room.sog', size: 32, arrayBuffer: async () => new ArrayBuffer(32) }), /ZIP/);
  const bytes = envelope();
  assert.equal(await readSogInput({ name: 'room.sog', size: 32, arrayBuffer: async () => bytes.buffer }), bytes.buffer);
});

test('decoded cap is inclusive and rejects missing, fractional and nonfinite counts', () => {
  assert.equal(MAX_SPLAT_COUNT, 500000);
  for (const count of [1, MAX_SPLAT_COUNT]) assert.doesNotThrow(() => assertDecodedSplatCount(count));
  for (const count of [0, -1, 1.5, NaN, Infinity, -Infinity, MAX_SPLAT_COUNT + 1, '2048', null, undefined]) {
    assert.throws(() => assertDecodedSplatCount(count));
  }
});

test('synthetic filenames are warnings, never identity proof; renamed input remains unknown', () => {
  for (const name of ['SYNTHETIC-NOT-A-ROOM.sog', 'synthetic-not-a-room-copy.sog']) {
    assert.deepEqual(localProvenance(name), { provenance: 'synthetic', synthetic: true, realRoomVerified: false });
  }
  assert.equal(localProvenance('arbitrary.sog', true).provenance, 'synthetic');
  for (const name of ['actual-room.sog', 'renamed-fixture.sog']) {
    assert.deepEqual(localProvenance(name), { provenance: 'unknown', synthetic: null, realRoomVerified: false });
  }
});

function response(chunks, declared = null) {
  const counters = { reads: 0, cancelled: 0, released: 0 };
  const reader = {
    async read() { counters.reads++; return chunks.length ? { done: false, value: chunks.shift() } : { done: true }; },
    async cancel() { counters.cancelled++; },
    releaseLock() { counters.released++; }
  };
  return { headers: { get: () => declared }, body: { getReader: () => reader }, counters };
}

test('fixture declared oversize is rejected without reading and cancels its body', async () => {
  const input = response([envelope()], String(MAX_SOG_BYTES + 1));
  await assert.rejects(readFixtureResponse(input), /64 MiB/);
  assert.deepEqual(input.counters, { reads: 0, cancelled: 1, released: 1 });
});

test('fixture observed oversize is rejected while streaming even with a small declared length', async () => {
  for (const declared of [null, '32']) {
    const input = response([envelope(), { byteLength: MAX_SOG_BYTES }], declared);
    await assert.rejects(readFixtureResponse(input), /64 MiB/);
    assert.deepEqual(input.counters, { reads: 2, cancelled: 1, released: 1 });
  }
});

test('fixture stream handles chunked valid envelope, mismatched length and invalid envelope', async () => {
  const bytes = envelope();
  const input = response([bytes.slice(0, 3), bytes.slice(3)], '32');
  assert.deepEqual(new Uint8Array(await readFixtureResponse(input)), bytes);
  assert.deepEqual(input.counters, { reads: 3, cancelled: 0, released: 1 });
  await assert.rejects(readFixtureResponse(response([bytes], '31')), /declared length/);
  await assert.rejects(readFixtureResponse(response([new Uint8Array(32)])), /ZIP/);
});
