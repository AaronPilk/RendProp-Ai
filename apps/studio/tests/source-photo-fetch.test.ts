import assert from "node:assert/strict";
import test from "node:test";
import { imageFromURL } from "../src/features/creative/media";

// A cloud photo already shown in the gallery sits in the browser cache. A
// conditional re-request can come back 304 without the cross-origin header and
// the browser then refuses the picture. The editor must always ask for a fresh
// copy, without cookies and without following redirects.
test("cloud source photos are fetched fresh, without credentials or redirects", async () => {
  const original = globalThis.fetch;
  const calls: Array<[unknown, RequestInit | undefined]> = [];
  globalThis.fetch = (async (input: unknown, init?: RequestInit) => {
    calls.push([input, init]);
    return new Response(null, { status: 403 });
  }) as typeof fetch;
  try {
    await assert.rejects(
      imageFromURL("https://media.example.invalid/photo.webp", "Living room"),
      /This photo link has expired/,
    );
  } finally {
    globalThis.fetch = original;
  }
  assert.equal(calls.length, 1);
  assert.equal(calls[0]![0], "https://media.example.invalid/photo.webp");
  assert.equal(calls[0]![1]?.cache, "no-store");
  assert.equal(calls[0]![1]?.credentials, "omit");
  assert.equal(calls[0]![1]?.redirect, "error");
});
