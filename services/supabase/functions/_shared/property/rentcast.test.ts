import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { rentcast } from "./rentcast.ts";
import { PropertyLookupFailure } from "./provider.ts";

const address = "PRIVATE-ADDRESS-SENTINEL";
async function closed<T>(transport: typeof fetch, run: () => Promise<T>) {
  const original = globalThis.fetch, key = Deno.env.get("RENTCAST_API_KEY");
  Deno.env.set("RENTCAST_API_KEY", "inert-rentcast-fixture");
  let calls = 0;
  globalThis.fetch = (input, init) => {
    calls++;
    const request = new Request(input, init);
    assertEquals(new URL(request.url).origin, "https://api.rentcast.io");
    assertEquals(request.method, "GET");
    return transport(input, init);
  };
  try { const result = await run(); return { result, calls }; }
  finally { globalThis.fetch = original; key === undefined ? Deno.env.delete("RENTCAST_API_KEY") : Deno.env.set("RENTCAST_API_KEY", key); }
}

Deno.test("RentCast valid facts and genuine404/empty matches retain existing modeled lookup behavior", async () => {
  for (const response of [new Response(null, { status: 404 }), Response.json([])]) {
    const r = await closed(async () => response, () => rentcast.lookup(address));
    assertEquals(r.result.facts, null); assertEquals(r.calls, 1);
  }
  const r = await closed(async () => Response.json([{ bedrooms: 3, bathrooms: 2.5, squareFootage: 1500, lastSalePrice: 123456 }]), () => rentcast.lookup(address));
  assertEquals(r.result.facts?.beds, 3); assertEquals(r.result.facts?.baths, 2.5);
  assertEquals(r.result.facts?.sqft, 1500); assertEquals(r.result.facts?.lastSalePriceCents, 12345600);
  assertEquals(r.calls, 1); assertEquals(rentcast.unitCents, 7);
});

Deno.test("RentCast auth/rate/server refusals are failures rather than invented property misses", async () => {
  for (const status of [401, 403, 429, 500]) {
    const r = await closed(async () => Response.json({ private: address }, { status }), async () => {
      const error = await assertRejects(() => rentcast.lookup(address));
      assert(error instanceof Error);
      assert(!error.message.includes(address));
    });
    assertEquals(r.calls, 1, "No provider retry is allowed");
  }
});

Deno.test("RentCast malformed successes and lost transport remain explicit unknown failures", async () => {
  for (const response of [new Response("not-json"), Response.json(null), Response.json(42), Response.json({ error: address }), Response.json({ bedrooms: "not a number" }), Response.json({ formattedAddress: {} }), Response.json(["invalid"])]) {
    const r = await closed(async () => response, async () => { await assertRejects(() => rentcast.lookup(address)); });
    assertEquals(r.calls, 1);
  }
  const r = await closed(async () => { throw new TypeError(address + " signed-url-secret"); }, async () => {
    const error = await assertRejects(() => rentcast.lookup(address));
      assert(error instanceof Error);
    assert(!error.message.includes(address) && !error.message.includes("signed-url-secret"));
  });
  assertEquals(r.calls, 1);
});

Deno.test("actual RentCast deadline abort is recorded as transport unknown without a retry", async () => {
  const nativeTimeout = globalThis.setTimeout;
  let deadlines = 0, aborted = false;
  globalThis.setTimeout = ((callback: Parameters<typeof setTimeout>[0], delay?: number, ...args: unknown[]) => {
    assertEquals(args.length, 0, "The provider deadline uses a zero-argument abort callback");
    if (delay === 12_000) deadlines++;
    return nativeTimeout(callback, delay === 12_000 ? 0 : delay);
  }) as typeof setTimeout;
  try {
    const r = await closed((input, init) => new Promise((_resolve, reject) => {
      const signal = new Request(input, init).signal;
      signal.addEventListener("abort", () => { aborted = true; reject(signal.reason); }, { once: true });
    }), async () => {
      const error = await assertRejects(() => rentcast.lookup(address), PropertyLookupFailure);
      assertEquals(error.outcome, "transport_unknown"); assertEquals(error.status, null);
    });
    assertEquals(r.calls, 1); assertEquals(deadlines, 1); assert(aborted);
  } finally { globalThis.setTimeout = nativeTimeout; }
});

Deno.test("RentCast deadline covers a stalled body after successful headers without inventing a priced miss", async () => {
  const nativeTimeout = globalThis.setTimeout;
  let deadlines = 0, aborted = false, body: ReadableStreamDefaultController<Uint8Array> | undefined;
  let watchdog: ReturnType<typeof setTimeout> | undefined;
  globalThis.setTimeout = ((callback: Parameters<typeof setTimeout>[0], delay?: number, ...args: unknown[]) => {
    assertEquals(args.length, 0, "The provider deadline uses a zero-argument abort callback");
    if (delay === 12_000) deadlines++;
    return nativeTimeout(callback, delay === 12_000 ? 0 : delay);
  }) as typeof setTimeout;
  try {
    const r = await closed(async (input, init) => {
      const signal = new Request(input, init).signal;
      return new Response(new ReadableStream<Uint8Array>({ start(controller) {
        body = controller;
        signal.addEventListener("abort", () => { aborted = true; controller.error(signal.reason); }, { once: true });
      } }), { status: 200, headers: { "x-request-id": "a9100000-0000-4000-8000-000000000099" } });
    }, async () => {
      const guard = new Promise<never>((_resolve, reject) => {
        watchdog = nativeTimeout(() => reject(new Error("Closed fixture watchdog: response body outlived the provider deadline")), 100);
      });
      const error = await assertRejects(() => Promise.race([rentcast.lookup(address), guard]), PropertyLookupFailure);
      assertEquals(error.outcome, "invalid_response"); assertEquals(error.status, 200);
      assertEquals(error.requestId, "a9100000-0000-4000-8000-000000000099");
    });
    assertEquals(r.calls, 1); assertEquals(deadlines, 1); assert(aborted);
  } finally {
    if (watchdog !== undefined) clearTimeout(watchdog);
    body?.error(new Error("Closed fixture cleanup"));
    globalThis.setTimeout = nativeTimeout;
  }
});
