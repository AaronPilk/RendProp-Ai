// http.test.ts — the bits of the shared HTTP layer that a public route's
// safety depends on.
//
//   deno test --allow-env --allow-net --allow-read _shared/http.test.ts
//
// Added by the S1 pre-money review for one reason: `readJson` buffers whatever
// a caller sends before any handler can look at it, and two of the new routes
// are reachable without a user JWT — /apple-subscriptions/notify is deployed
// --no-verify-jwt so Apple can reach it, and /events accepts the project anon
// key, which ships inside the app. One POST of a few hundred megabytes to
// either is an out-of-memory kill of the isolate, and a per-IP limiter does not
// help when one request is enough. `readJsonLimited` is what stops that, so it
// gets tests.

import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, readJsonLimited } from "./http.ts";

function post(body: BodyInit, headers: Record<string, string> = {}): Request {
  return new Request("https://example.test/x", { method: "POST", body, headers });
}

/** A body with NO content-length, delivered in chunks — the chunked-encoding case. */
function streamed(chunks: Uint8Array[]): Request {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const c of chunks) controller.enqueue(c);
      controller.close();
    },
  });
  // deno-lint-ignore no-explicit-any
  return new Request("https://example.test/x", { method: "POST", body: stream, ...({ duplex: "half" } as any) });
}

Deno.test("readJsonLimited parses a body inside the cap", async () => {
  const req = post(JSON.stringify({ signedPayload: "abc", n: 1 }));
  const body = await readJsonLimited<{ signedPayload: string; n: number }>(req, 1024);
  assertEquals(body.signedPayload, "abc");
  assertEquals(body.n, 1);
});

Deno.test("readJsonLimited refuses an oversized body by its declared length", async () => {
  const req = post(JSON.stringify({ pad: "x".repeat(4096) }));
  const err = await assertRejects(() => readJsonLimited(req, 512), HttpError);
  assertEquals(err.status, 413);
  assertEquals(err.code, "payload_too_large");
});

Deno.test("readJsonLimited refuses an oversized body with NO declared length", async () => {
  // Chunked transfer encoding: there is no Content-Length to check, so the
  // ceiling has to be enforced while the stream is being read. This is the case
  // that matters — an attacker simply omits the header.
  const chunk = new TextEncoder().encode("x".repeat(1024));
  const req = streamed([chunk, chunk, chunk, chunk]);
  assertEquals(req.headers.get("content-length"), null);
  const err = await assertRejects(() => readJsonLimited(req, 2048), HttpError);
  assertEquals(err.status, 413);
});

Deno.test("readJsonLimited accepts a chunked body that stays inside the cap", async () => {
  const enc = new TextEncoder();
  const req = streamed([enc.encode('{"a":'), enc.encode("1"), enc.encode("}")]);
  assertEquals(await readJsonLimited<{ a: number }>(req, 1024), { a: 1 });
});

Deno.test("readJsonLimited is a 400, not a 500, on junk", async () => {
  const err = await assertRejects(() => readJsonLimited(post("not json"), 1024), HttpError);
  assertEquals(err.status, 400);
});

Deno.test("readJsonLimited counts BYTES, not characters", async () => {
  // A multi-byte payload must not slip past a byte ceiling by being short in
  // characters. "é" is two bytes; 400 of them plus the JSON scaffolding is over
  // 512 bytes but only ~410 characters.
  const json = JSON.stringify({ s: "é".repeat(400) });
  const err = await assertRejects(() => readJsonLimited(post(json), 512), HttpError);
  assertEquals(err.status, 413);
});
