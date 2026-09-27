import assert from "node:assert/strict";
import test from "node:test";
import {createHash} from "node:crypto";
import {hashFileInChunks, PROXY_LIMITS, proxyDimensions, validateProxyInput} from "../src/editor/proxy";
test("large-original fingerprints match native SHA-256 with only bounded slices", async () => {
  const bytes = new Uint8Array(PROXY_LIMITS.hashChunkBytes * 3 + 137);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 31 + Math.floor(i / 997)) % 256;
  const file = new Blob([bytes]); let largest = 0, reads = 0;
  const slice = file.slice.bind(file);
  file.arrayBuffer = async () => {throw new Error("An unbounded original read is forbidden");};
  file.slice = (start, end, type) => {largest = Math.max(largest, (end ?? file.size) - (start ?? 0)); reads++; return slice(start, end, type);};
  const result = await hashFileInChunks(file, new AbortController().signal);
  assert.equal(result, createHash("sha256").update(bytes).digest("hex")); assert.equal(reads, 4); assert.equal(largest, PROXY_LIMITS.hashChunkBytes);
});
test("hash cancellation stops before reading more chunks and oversized/unsupported originals fail", async () => {
  const abort = new AbortController(); let reads = 0;
  const file = new Blob([new Uint8Array(PROXY_LIMITS.hashChunkBytes * 3)]), slice = file.slice.bind(file);
  file.slice = (...args) => {reads++; return slice(...args);};
  await assert.rejects(hashFileInChunks(file, abort.signal, () => abort.abort()), /cancel|abort/i); assert.equal(reads, 1);
  assert.throws(() => validateProxyInput({name:"huge.mov",type:"video/quicktime",size:PROXY_LIMITS.originalBytes+1}), /2 GiB/);
  assert.throws(() => validateProxyInput({name:"document.html",type:"text/html",size:10}), /MP4/);
  assert.doesNotThrow(() => validateProxyInput({name:"room.mov",type:"video/quicktime",size:200*1024*1024}));
});
test("editing copies preserve aspect ratio, fit720p, use even pixels, and do not upscale", () => {
  assert.deepEqual(proxyDimensions(3840,2160), {width:1280,height:720});
  assert.deepEqual(proxyDimensions(2160,3840), {width:720,height:1280});
  assert.deepEqual(proxyDimensions(1920,1920), {width:720,height:720});
  assert.deepEqual(proxyDimensions(640,360), {width:640,height:360});
  assert.throws(() => proxyDimensions(8000,6000), /4K/);
});
