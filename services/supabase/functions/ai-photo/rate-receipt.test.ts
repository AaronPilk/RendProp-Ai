// Compile the production photo/voice/chapter guard and refund bodies, and use
// the real rate-receipt transport against a synthetic fixed-window database.
// No paid provider, project, funding or storage requests are permitted.
import { assert, assertEquals, assertRejects, AssertionError } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";

Deno.env.set("SUPABASE_URL", "https://rate-callsite.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-rate-service");

const features = [
  { endpoint: "ai-photo", guard: "guardEdit", refund: "refundEditCharge", burst: "aiphoto", monthly: "aiphotomo", burstMax: 40 },
  { endpoint: "ai-photo", guard: "guardHelper", refund: "refundHelperCharge", burst: "aiphotohelp", monthly: null, burstMax: 120 },
  { endpoint: "ai-voice", guard: "guardTTS", refund: "refundCharge", burst: "aivoice", monthly: "aivoicemo", burstMax: 20 },
  { endpoint: "ai-chapters", guard: "guardChapters", refund: "refundCharge", burst: "aichapters", monthly: "chaptersmo", burstMax: 10 },
] as const;
type Feature = typeof features[number];
type Row = { count: number; windowSeconds: number; windowStart: string };
const org = "synthetic-rate-org";
const keyFor = (prefix: string) => `${prefix}:${org}`;
const window1 = "2026-10-07T00:00:00.123456Z";
const window2 = "2026-11-08T00:00:00.654321Z";

function actualFunction(source: string, name: string): string {
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf("\n}\n", start);
  assert(start >= 0 && end > start, `Extract actual ${name}`);
  return source.slice(start, end + 3).replace(`async function ${name}`, `export async function ${name}`);
}

async function fixture(feature: Feature, oldRefund = false) {
  const source = await Deno.readTextFile(new URL(`../${feature.endpoint}/index.ts`, import.meta.url));
  const guard = actualFunction(source, feature.guard);
  let refund = actualFunction(source, feature.refund);
  if (oldRefund) {
    // Restore the exact historical transport defect while keeping the current
    // admission and unchanged next-window invariant.
    refund = refund.replace("refundRateReceipt(charge.monthlyReceipt)", "refundRateLimit(charge.monthlyKey, MONTH_SECONDS, 1)")
      .replace("refundRateReceipt(charge.burstReceipt)", `refundRateLimit(charge.burstKey, ${feature.guard === "guardHelper" ? "HELP_WINDOW_SECONDS" : feature.endpoint === "ai-photo" ? "EDIT_WINDOW_SECONDS" : feature.endpoint === "ai-voice" ? "TTS_WINDOW_SECONDS" : "BURST_WINDOW_SECONDS"}, 1)`);
    assert(refund.includes("refundRateLimit("), "Compile the old refund transport control");
  }
  const constants = source.split("\n").filter((line) => /^const (?:EDIT_|HELP_|TTS_|BURST_|MONTH_SECONDS)/.test(line)).join("\n");
  const module = await import(`data:application/typescript;base64,${btoa(unescape(encodeURIComponent(`
    import {HttpError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {requiredIdempotencyKey} from ${JSON.stringify(new URL("../_shared/idempotency.ts", import.meta.url).href)};
    import {chargeRateReceipt,refundRateReceipt,refundRateLimit,durableRateLimit,type RateChargeReceipt} from ${JSON.stringify(new URL("../_shared/ratelimit.ts", import.meta.url).href)};
    type PaidAiCaller={id:string};type EditCharge=any;type HelperCharge=any;type Charge=any;
    ${constants}
    export const authority={role:"owner",cap:400};
    const requireEditorRole=async()=>{if(authority.role==="marketing")throw new HttpError(403,"Read only");return ${JSON.stringify(org)};};
    const entitlementForCharge=async()=>({plan:"team",photo_edits_per_month:authority.cap,reels_per_month:authority.cap,renders_per_month:authority.cap});
    const quotaError=()=>new HttpError(402,"Synthetic allowance exhausted");
    const assertPaidAiIdentity=async()=>{};
    const adminClient=()=>({from(){const q:any={select(){return q;},eq(){return q;},maybeSingle:async()=>({data:{role:authority.role},error:null})};return q;}});
    ${guard}
    ${refund}
    export const run=${feature.guard},giveBack=${feature.refund};
    // Separate instances even when two features live in the same source file.
    export const fixtureIdentity=${JSON.stringify(crypto.randomUUID())};
  `)))}`);
  const originalFetch = globalThis.fetch;
  const rows = new Map<string, Row>();
  const windows = new Map([[300, window1], [2592000, window1], [120, window1]]);
  const calls: { rpc: string; args: Record<string, unknown> }[] = [];
  const state = { refundUnavailable: false, monthlyUnavailable: false };
  globalThis.fetch = (async (input, init) => {
    const req = new Request(input, init);
    const url = new URL(req.url);
    assertEquals(url.origin, "https://rate-callsite.invalid");
    assertEquals(req.method, "POST");
    const rpc = url.pathname.replace("/rest/v1/rpc/", "");
    const args = await req.json(); calls.push({ rpc, args });
    const key = args.p_key as string, seconds = args.p_window_seconds as number;
    if (rpc === "bump_rate_receipt" || rpc === "bump_rate") {
      if (state.monthlyUnavailable && seconds === 2592000) {
        return new Response(JSON.stringify({ message: "Synthetic unknown meter response", code: "XX000" }), { status: 503, headers: { "content-type": "application/json" } });
      }
      const current = windows.get(seconds)!;
      assert(current, "Only the original quota/dedupe windows are admitted");
      let row = rows.get(key);
      if (!row || row.windowStart !== current) row = { count: 0, windowSeconds: seconds, windowStart: current };
      row.count += args.p_cost; rows.set(key, row);
      const accepted = row.count <= args.p_max;
      return Response.json(rpc === "bump_rate_receipt" ? { accepted, window_start: row.windowStart } : accepted);
    }
    if (rpc === "refund_rate_receipt" || rpc === "refund_rate") {
      if (state.refundUnavailable) return new Response(JSON.stringify({ message: "Synthetic refund outage", code: "XX000" }), { status: 503, headers: { "content-type": "application/json" } });
      const row = rows.get(key);
      const matches = !!row && row.windowSeconds === seconds && row.count > 0 &&
        (rpc === "refund_rate_receipt" ? row.windowStart === args.p_window_start : row.windowStart === windows.get(seconds));
      if (matches) row.count = Math.max(0, row.count - args.p_cost);
      return Response.json(matches);
    }
    throw new Error(`Unexpected non-rate RPC ${rpc}`);
  }) as typeof fetch;
  return {
    calls, rows, windows, state, authority: module.authority,
    run: (idem: string = crypto.randomUUID()) => module.run({ id: "synthetic-actor" }, new Request("https://caller.invalid/ai", { headers: { "idempotency-key": idem } }), org),
    refund: (charge: unknown) => module.giveBack(charge),
    close: () => { globalThis.fetch = originalFetch; },
  };
}

async function lateFailure(feature: Feature, oldRefund = false) {
  const f = await fixture(feature, oldRefund);
  try {
    const original = await f.run();
    f.windows.set(300, window2); f.windows.set(2592000, window2); f.windows.set(120, window2);
    await f.run(); await f.run();
    await f.refund(original);
    assertEquals(f.rows.get(keyFor(feature.burst))?.count, 2, "Late failure must not refund newer same-key burst work");
    if (feature.monthly) assertEquals(f.rows.get(keyFor(feature.monthly))?.count, 2, "Late failure must not refund newer same-key monthly work");
  } finally { f.close(); }
}

for (const feature of features) {
  Deno.test(`${feature.guard}: exact original receipt transport and current-window refund`, async () => {
    const f = await fixture(feature);
    try {
      const charge = await f.run();
      assertEquals(charge.orgId, org);
      assertEquals(charge.burstReceipt, { key: keyFor(feature.burst), windowSeconds: 300, windowStart: window1 });
      if (feature.monthly) assertEquals(charge.monthlyReceipt, { key: keyFor(feature.monthly), windowSeconds: 2592000, windowStart: window1 });
      const allowance = f.calls.filter((call) => call.rpc === "bump_rate_receipt");
      assertEquals(allowance[0].args, { p_key: keyFor(feature.burst), p_max: feature.burstMax, p_window_seconds: 300, p_cost: 1 });
      if (feature.monthly) assertEquals(allowance[1].args, { p_key: keyFor(feature.monthly), p_max: 400, p_window_seconds: 2592000, p_cost: 1 });
      await f.refund(charge);
      assertEquals(f.rows.get(keyFor(feature.burst))?.count, 0);
      if (feature.monthly) assertEquals(f.rows.get(keyFor(feature.monthly))?.count, 0);
      assert(f.calls.filter((call) => call.rpc.startsWith("refund")).every((call) => call.rpc === "refund_rate_receipt" && call.args.p_window_start === window1));
      if (feature.endpoint === "ai-voice") {
        const dedupe = [...f.rows.entries()].find(([key]) => key.startsWith("aivoiceidem:"));
        assertEquals(dedupe?.[1].count, 1, "Usage refund does not release dedupe");
      }
    } finally { f.close(); }
  });
  Deno.test(`${feature.guard}: late failure leaves newer same-key windows untouched`, () => lateFailure(feature));
  Deno.test(`${feature.guard}: compiled historical refund fails unchanged rollover invariant`, async () => {
    await assertRejects(() => lateFailure(feature, true), AssertionError, "Late failure must not refund newer same-key");
  });
  Deno.test(`${feature.guard}: refund outage leaves allowance charged without replacing failure`, async () => {
    const f = await fixture(feature);
    try {
      const charge = await f.run(); f.state.refundUnavailable = true;
      await f.refund(charge);
      assertEquals(f.rows.get(keyFor(feature.burst))?.count, 1);
      if (feature.monthly) assertEquals(f.rows.get(keyFor(feature.monthly))?.count, 1);
    } finally { f.close(); }
  });
  Deno.test(`${feature.guard}: read-only membership is refused before any rate charge`, async () => {
    const f = await fixture(feature);
    try {
      f.authority.role = "marketing";
      const error = await assertRejects(() => f.run(), HttpError);
      assertEquals(error.status, 403);
      assertEquals(f.calls, []);
    } finally { f.close(); }
  });
  Deno.test(`${feature.guard}: burst exhaustion preserves monthly allowance and dedupe`, async () => {
    const f = await fixture(feature);
    try {
      f.rows.set(keyFor(feature.burst), { count: feature.burstMax, windowSeconds: 300, windowStart: window1 });
      const error = await assertRejects(() => f.run("same-burst-rejected-operation"), HttpError);
      assertEquals(error.status, 429);
      assertEquals(f.calls.filter((call) => call.args.p_window_seconds === 2592000).length, 0);
      assertEquals(f.calls.filter((call) => call.rpc.startsWith("refund")).length, 0);
      if (feature.endpoint === "ai-voice") {
        const duplicate = await assertRejects(() => f.run("same-burst-rejected-operation"), HttpError);
        assertEquals(duplicate.status, 409);
      }
    } finally { f.close(); }
  });
  if (feature.monthly) {
    Deno.test(`${feature.guard}: zero plan cap refuses before usage or dedupe charges`, async () => {
      const f = await fixture(feature);
      try {
        f.authority.cap = 0;
        const error = await assertRejects(() => f.run(), HttpError);
        assertEquals(error.status, 402);
        assertEquals(f.calls, []);
      } finally { f.close(); }
    });
    Deno.test(`${feature.guard}: burst rollover refunds only the still-original monthly charge`, async () => {
      const f = await fixture(feature);
      try {
        const original = await f.run(); f.windows.set(300, window2); f.windows.set(120, window2);
        await f.run(); await f.refund(original);
        assertEquals(f.rows.get(keyFor(feature.burst))?.count, 1);
        assertEquals(f.rows.get(keyFor(feature.monthly!))?.count, 1);
      } finally { f.close(); }
    });
    Deno.test(`${feature.guard}: confirmed exhausted monthly allowance returns only the original burst receipt`, async () => {
      const f = await fixture(feature);
      try {
        f.authority.cap = 1;
        f.rows.set(keyFor(feature.monthly!), { count: 1, windowSeconds: 2592000, windowStart: window1 });
        await assertRejects(() => f.run(), HttpError, "Synthetic allowance exhausted");
        assertEquals(f.rows.get(keyFor(feature.burst))?.count, 0);
        assertEquals(f.rows.get(keyFor(feature.monthly!))?.count, 2, "Rejected monthly attempt is not claimed as successful allowance");
        assertEquals(f.calls.filter((call) => call.rpc.startsWith("refund")), [{ rpc: "refund_rate_receipt", args: { p_key: keyFor(feature.burst), p_window_seconds: 300, p_window_start: window1, p_cost: 1 } }]);
      } finally { f.close(); }
    });
    Deno.test(`${feature.guard}: unconfirmed monthly charge refuses admission without speculative refund`, async () => {
      const f = await fixture(feature);
      try {
        f.state.monthlyUnavailable = true;
        const error = await assertRejects(() => f.run(), HttpError);
        assertEquals(error.status, 503);
        const confirmedBurstReturned = feature.endpoint === "ai-chapters";
        assertEquals(f.rows.get(keyFor(feature.burst))?.count, confirmedBurstReturned ? 0 : 1);
        assertEquals(f.calls.filter((call) => call.rpc.startsWith("refund")), confirmedBurstReturned ? [{ rpc: "refund_rate_receipt", args: { p_key: keyFor(feature.burst), p_window_seconds: 300, p_window_start: window1, p_cost: 1 } }] : []);
        assertEquals(f.rows.get(keyFor(feature.monthly!)), undefined, "An unknown monthly response never authorizes a monthly refund");
      } finally { f.close(); }
    });
  }
}
