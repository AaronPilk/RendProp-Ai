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

import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, readJson, readJsonLimited, respondError, throwRpc } from "./http.ts";

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

// ── Canonical uuid casing (2026-10-11 incident) ───────────────────────────────
// The phone sends `UUID.uuidString` in uppercase; Postgres returns lowercase.
// Every identity `===` downstream must see the canonical form, so the HTTP
// boundary lowercases uuid-shaped path segments and the named id keys of a
// body — and nothing else.
import { canonicalIds, canonicalUuid, CANONICAL_ID_KEYS, pathSegments } from "./http.ts";
const UPPER = "55739BCB-E589-853B-AD28-92A3A5521823", LOWER = UPPER.toLowerCase();
Deno.test("readJson / readJsonLimited lowercase uuid identity keys and leave everything else byte-identical", async () => {
  const payload = { listing_id: UPPER, org_id: UPPER, asset_id: UPPER, lead_id: UPPER, batch_id: UPPER, idempotency_key: UPPER,
    key: "renders/ABC/Photo.JPG", label: "Living Room", nested: { listing_id: UPPER }, ids: [UPPER], note: null, n: 7 };
  for (const read of [
    (req: Request) => readJson<typeof payload>(req),
    (req: Request) => readJsonLimited<typeof payload>(req, 8192),
  ]) {
    const body = await read(new Request("https://x.invalid/", { method: "POST", body: JSON.stringify(payload), headers: { "content-type": "application/json" } }));
    assertEquals([body.listing_id, body.org_id, body.asset_id, body.lead_id], [LOWER, LOWER, LOWER, LOWER]);
    // Idempotency keys, batch ids, storage keys and free text keep their casing.
    assertEquals([body.batch_id, body.idempotency_key, body.key, body.label], [UPPER, UPPER, "renders/ABC/Photo.JPG", "Living Room"]);
    // Only top-level keys are touched: nested objects and arrays are the handler's business.
    assertEquals(body.nested.listing_id, UPPER); assertEquals(body.ids, [UPPER]);
    assertEquals([body.note, body.n], [null, 7]);
  }
  // A non-object body is returned untouched.
  assertEquals(await readJson<unknown>(new Request("https://x.invalid/", { method: "POST", body: "[1,2]" })), [1, 2]);
});
Deno.test("pathSegments lowercases uuid segments only; slugs, handles and words keep their casing", () => {
  const req = (path: string) => new Request("https://x.invalid" + path);
  assertEquals(pathSegments(req(`/functions/v1/listings/${UPPER}/facts`), "listings"), [LOWER, "facts"]);
  assertEquals(pathSegments(req(`/leads/${UPPER}`), "leads"), [LOWER]);
  assertEquals(pathSegments(req("/tours/G2afBGmv32/delivery"), "tours"), ["G2afBGmv32", "delivery"]);
  assertEquals(pathSegments(req("/portfolio/RichardT"), "portfolio"), ["RichardT"]);
  assertEquals(pathSegments(req("/tours/business-logo/" + UPPER), "tours"), ["business-logo", LOWER]);
});
Deno.test("canonicalUuid touches only uuid-shaped strings; canonicalIds only the listed keys", () => {
  assertEquals(canonicalUuid(UPPER), LOWER); assertEquals(canonicalUuid(LOWER), LOWER);
  assertEquals(canonicalUuid("not-a-uuid"), "not-a-uuid"); assertEquals(canonicalUuid(UPPER + "x"), UPPER + "x");
  assertEquals(canonicalUuid(42), 42); assertEquals(canonicalUuid(null), null);
  assertEquals(canonicalIds({ listing_id: UPPER, batch_id: UPPER }, CANONICAL_ID_KEYS), { listing_id: LOWER, batch_id: UPPER });
  assert(CANONICAL_ID_KEYS.includes("listing_id") && CANONICAL_ID_KEYS.includes("org_id") && !CANONICAL_ID_KEYS.includes("batch_id" as never));
});
