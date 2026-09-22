import { assertSogEnvelope } from './benchmark.mjs';

// These are spike admission limits, not a phone-memory guarantee. The engine
// decodes ZIP/WebP resources before numSplats is exposed; small encoded files
// can still demand large texture allocations during that decode.
export const MAX_SOG_BYTES = 64 * 1024 * 1024;
export const MAX_SPLAT_COUNT = 500000;

export function assertSogInput(name, size) {
  if (typeof name !== 'string' || !name.toLowerCase().endsWith('.sog')) {
    throw new Error('Choose a bundled .sog file');
  }
  if (!Number.isSafeInteger(size) || size < 22 || size > MAX_SOG_BYTES) {
    throw new Error('SOG input must be 22 bytes to 64 MiB');
  }
}

export async function readSogInput(file) {
  // Inspect File metadata BEFORE reading the entire object. Rechecking actual
  // bytes also keeps test adapters and non-File callers from bypassing the cap.
  assertSogInput(file.name, file.size);
  const bytes = await file.arrayBuffer();
  assertSogInput(file.name, bytes.byteLength);
  if (bytes.byteLength !== file.size) throw new Error('SOG byte length differs from the selected file');
  assertSogEnvelope(file.name, bytes);
  return bytes;
}

export function assertDecodedSplatCount(count) {
  if (!Number.isSafeInteger(count) || count <= 0 || count > MAX_SPLAT_COUNT) {
    throw new Error('Decoded SOG must contain 1 to 500,000 splats');
  }
}

export function localProvenance(name, explicitFixture = false) {
  // A filename can warn us that input is synthetic; it cannot prove a measured
  // room. Renaming the smoke fixture must never turn it into real-room proof.
  const synthetic = explicitFixture || /^SYNTHETIC-NOT-A-ROOM/i.test(name);
  return { provenance: synthetic ? 'synthetic' : 'unknown', synthetic: synthetic ? true : null, realRoomVerified: false };
}

export async function readFixtureResponse(response) {
  // Even the opt-in local fixture path must not buffer an unlimited response.
  // The declared length is an early rejection only; count observed bytes too.
  const header = response.headers.get('content-length');
  if (!response.body) throw new Error('Fixture response has no body');
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0, finished = false;
  try {
    if (header !== null) assertSogInput('fixture.sog', Number(header));
    for (;;) {
      const { done, value } = await reader.read();
      if (done) { finished = true; break; }
      if (value.byteLength > MAX_SOG_BYTES - length) throw new Error('Fixture exceeds 64 MiB');
      length += value.byteLength;
      chunks.push(value);
    }
    assertSogInput('fixture.sog', length);
    if (header !== null && length !== Number(header)) throw new Error('Fixture byte length differs from its declared length');
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    assertSogEnvelope('fixture.sog', bytes.buffer);
    return bytes.buffer;
  } finally {
    if (!finished) await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
