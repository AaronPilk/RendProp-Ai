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

import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, readJsonLimited, respondError, throwRpc } from "./http.ts";

Deno.test("handled and unexpected server errors emit classification without private error contents", async () => {
  const original = console.error;
  const logs: unknown[][] = [];
  console.error = (...args: unknown[]) => { logs.push(args); };
  const privateValue = "buyer@fixture.invalid https://private.invalid/source?token=synthetic-secret customer prompt";
  try {
    const unexpected = new Error(privateValue);
    unexpected.stack = privateValue;
    const answer = respondError(unexpected);
    assertEquals(answer.status, 500);
    assertEquals((await answer.json()).code, "internal");
    respondError(new HttpError(503, privateValue, "upstream", { token: privateValue }));
    const malformed = new HttpError(502, "Safe response");
    malformed.code = privateValue as typeof malformed.code;
    respondError(malformed);
    assertEquals(logs.map(args => JSON.parse(String(args[0]))), [
      { event: "http_server_error", status: 500, code: "internal", kind: "unexpected" },
      { event: "http_server_error", status: 503, code: "upstream", kind: "handled" },
      { event: "http_server_error", status: 502, code: "internal", kind: "handled" },
    ]);
    assertEquals(JSON.stringify(logs).includes("fixture.invalid"), false);
    assertEquals(logs.every(args => args.length === 1), true);
    respondError(new HttpError(401, "Sign in"));
    respondError(new HttpError(402, "Quota reached", "quota_exceeded"));
    assertEquals(logs.length, 3);
  } finally { console.error = original; }
});

Deno.test("unexpected SQL errors are unavailable responses, with no private SQL or row data", () => {
  const secret = 'duplicate key on private_buyers: buyer@fixture.invalid';
  const error = assertThrows(() => throwRpc(secret), HttpError);
  assertEquals(error.status, 503);
  assertEquals(error.message, "This action is temporarily unavailable. Please try again.");
  const quota = assertThrows(() => throwRpc("RP402: photo limit reached"), HttpError);
  assertEquals(quota.status, 402); assertEquals(quota.code, "quota_exceeded");
  assertEquals(quota.message, "photo limit reached");
});

Deno.test("trial pool RPC refusals retain a distinct availability code in the wire response", async () => {
  for (const pool of ["cap", "closed"]) {
    const error = assertThrows(() => throwRpc(`RP402: Free-trial AI limit reached [pool=${pool}]`), HttpError);
    const response = respondError(error);
    assertEquals(response.status, 402);
    assertEquals(await response.json(), {
      code: "trial_capacity_unavailable",
      error: "Trial AI is temporarily unavailable. Nothing was charged. Please try again later or contact support.",
    });
  }
  for (const kind of ["free", "trial", "retail"]) {
    const error = assertThrows(() => throwRpc(`RP402: AI usage limit reached [kind=${kind}]`), HttpError);
    assertEquals(error.code, "quota_exceeded");
  }
});

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
