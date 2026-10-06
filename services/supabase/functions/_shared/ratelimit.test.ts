// Exercise the production limiter through the real Supabase client. Fetch is
// restricted to a synthetic bump_rate endpoint; no project or provider calls.
import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, respondError } from "./http.ts";

Deno.env.set("SUPABASE_URL", "https://rate-fixture.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fixture-service");
const { durableRateLimit, publicRateLimit } = await import("./ratelimit.ts");

type Result = "allowed" | "limited" | "rpc-error" | "network-error" | "null" | "malformed";
async function fixture<T>(result: Result, run: () => Promise<T>) {
  const previousFetch = globalThis.fetch;
  const calls: Record<string, unknown>[] = [];
  try {
    globalThis.fetch = async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.url, "https://rate-fixture.invalid/rest/v1/rpc/bump_rate");
      assertEquals(req.method, "POST");
      calls.push(await req.json());
      if (result === "network-error") throw new Error("synthetic connection lost");
      const body = result === "allowed" ? true : result === "limited" ? false
        : result === "null" ? null : result === "malformed" ? { allowed: true }
        : { message: "synthetic database unavailable", code: "XX000" };
      return new Response(JSON.stringify(body), {
        status: result === "rpc-error" ? 503 : 200,
        headers: { "content-type": "application/json" },
      });
    };
    return { value: await run(), calls };
  } finally {
    globalThis.fetch = previousFetch;
  }
}

Deno.test("durable meter preserves authoritative acceptance and cost arguments", async () => {
  const f = await fixture("allowed", () => durableRateLimit("paid:fixture", 25, 2592000, 2.6));
  assertEquals(f.value, true);
  assertEquals(f.calls, [{ p_key: "paid:fixture", p_window_seconds: 2592000, p_max: 25, p_cost: 3 }]);
});

Deno.test("authoritative exhausted quota returns false without a fallback", async () => {
  for (const limit of [durableRateLimit, publicRateLimit]) {
    const f = await fixture("limited", () => limit("limited:fixture", 25, 2592000));
    assertEquals(f.value, false);
    assertEquals(f.calls.length, 1);
  }
});

for (const result of ["rpc-error", "network-error", "null", "malformed"] as const) {
  Deno.test(`paid admission refuses ${result} before any provider work, including retries`, async () => {
    let providerCalls = 0;
    const f = await fixture(result, async () => {
      for (let isolate = 0; isolate < 3; isolate++) {
        // Distinct keys stand in for fresh isolates: none may earn a degraded
        // allowance merely because its memory counter starts empty.
        const error = await assertRejects(async () => {
          if (await durableRateLimit(`paid:outage:${isolate}`, 100, 2592000)) providerCalls++;
        }, HttpError);
        assertEquals(error.status, 503);
        assertEquals(error.code, "upstream");
        const response = respondError(error);
        assertEquals(response.status, 503);
        assertEquals((await response.json()).code, "upstream");
      }
    });
    assertEquals(providerCalls, 0);
    assertEquals(f.calls.length >= 3, true);
  });
}

Deno.test("unbilled public ingestion explicitly retains its quarter-ceiling fallback", async () => {
  const key = `public:outage:${crypto.randomUUID()}`;
  const f = await fixture("rpc-error", async () => {
    const outcomes = [];
    for (let n = 0; n < 4; n++) outcomes.push(await publicRateLimit(key, 12, 60));
    return outcomes;
  });
  assertEquals(f.value, [true, true, true, false]);
  assertEquals(f.calls.length, 4);
});

Deno.test("public degraded batches still account for each unit", async () => {
  const key = `public:batch:${crypto.randomUUID()}`;
  const f = await fixture("rpc-error", async () => [
    await publicRateLimit(key, 16, 60, 3),
    await publicRateLimit(key, 16, 60, 2),
  ]);
  assertEquals(f.value, [true, false]);
});

Deno.test("exact paid charge and refund transport pins the same server window", async () => {
  const { chargeRateReceipt, refundRateReceipt } = await import("./ratelimit.ts");
  const original = globalThis.fetch, calls: unknown[] = [];
  try {
    globalThis.fetch = async (input, init) => {
      const req = new Request(input, init), body = await req.json(); calls.push({ url: req.url, body });
      return new Response(JSON.stringify(req.url.endsWith("bump_rate_receipt") ? { accepted: true, window_start: "2026-10-05T00:00:00.123456Z" } : false), { headers: { "content-type": "application/json" } });
    };
    const charged = await chargeRateReceipt("reelmo:synthetic", 25, 2592000);
    assertEquals(charged.accepted, true);
    assertEquals(await refundRateReceipt(charged.receipt), false);
    assertEquals(calls, [
      { url: "https://rate-fixture.invalid/rest/v1/rpc/bump_rate_receipt", body: { p_key: "reelmo:synthetic", p_max: 25, p_window_seconds: 2592000, p_cost: 1 } },
      { url: "https://rate-fixture.invalid/rest/v1/rpc/refund_rate_receipt", body: { p_key: "reelmo:synthetic", p_window_seconds: 2592000, p_window_start: "2026-10-05T00:00:00.123456Z", p_cost: 1 } },
    ]);
    globalThis.fetch = async () => new Response(JSON.stringify({ accepted: true }), { headers: { "content-type": "application/json" } });
    await assertRejects(() => chargeRateReceipt("reelmo:synthetic", 25, 2592000), HttpError, "could not be confirmed");
  } finally { globalThis.fetch = original; }
});
