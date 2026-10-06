import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";
import { submitReservedVideo, VideoDispatchUnconfirmed } from "./cost-reservation.ts";

const step: RouteStep = {
  route_id: "fixture-route", task: "video.upscale_4k", provider: "fal", model: "topaz/upscale/video",
  unit: "second", unit_cents: 16, capabilities: ["v2v"], max_latency_s: 120,
  min_plan: "pro", same_model_as: null, privacy_tier: "no_retention", enabled: true,
};
const options = {
  // Deliberately low-entropy synthetic idempotency key; never a credential.
  actorId: "fixture-actor", orgId: "fixture-org", key: "aaaaaaaa",
  feature: "drone_render" as const, steps: [step], seconds: 300,
  input: { task: "video.upscale_4k", video_url: "https://private-media.invalid/customer-video", extra: { target_fps: 60 } },
  meta: { tier: "4k60" },
  allowance: { monthlyWindowStart: "2026-10-05T00:00:00Z", burstWindowStart: "2026-10-05T01:00:00Z" },
};

function fixture(patch: { reserve?: unknown; reserveError?: string; submitError?: boolean; settleError?: boolean; settleThrow?: boolean; wrongReceipt?: boolean } = {}) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let submissions = 0;
  const deps = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      if (name === "serving_cost_reserve") return Promise.resolve({data:{reserved:true},error:null});
      if (name === "serving_cost_finish") return Promise.resolve({data:{finished:true},error:null});
      // The unit-arithmetic cases use synthetic aerial models under explicit
      // private QA sponsorship; they do not claim a retail tariff exists.
      if (name === "org_has_internal_testing_grant") return Promise.resolve({data:true,error:null});
      if (name === "app_video_cost_reserve_v2") return Promise.resolve({
        data: "reserve" in patch ? patch.reserve : { reserved: true },
        error: patch.reserveError ? { message: patch.reserveError } : null,
      });
      assertEquals(name, "app_video_cost_settle");
      if (patch.settleThrow) throw new Error("synthetic disconnected settlement");
      return Promise.resolve({ data: { settled: true }, error: patch.settleError ? { message: "unavailable" } : null });
    },
    submit: (selected: RouteStep) => {
      assertEquals(calls.at(-1)?.name, "serving_cost_reserve");
      submissions++;
      if (patch.submitError) throw new Error("synthetic lost acceptance");
      return Promise.resolve({ step: selected, value: { id: patch.wrongReceipt ? "" : "provider-receipt" }, latency_ms: 3 });
    },
  };
  return { calls, get legacyCalls(){return calls.filter(c=>c.name.startsWith("app_video_cost_"));}, deps, submissions: () => submissions };
}

Deno.test("video price is durably reserved before one POST and settled once, without media in journal", async () => {
  const f = fixture();
  const result = await submitReservedVideo(options, f.deps);
  assertEquals(f.submissions(), 1);
  assertEquals(f.legacyCalls.map((c) => c.name), ["app_video_cost_reserve_v2", "app_video_cost_settle"]);
  assertEquals(f.legacyCalls[0].args.p_hold_cents, 4800);
  assertEquals(f.calls.find(c=>c.name === "serving_cost_reserve")?.args.p_hold_cents, 4800);
  assertEquals(f.legacyCalls[0].args.p_units, 300);
  assertEquals(f.legacyCalls[0].args.p_unit_cost_cents, 16);
  assert(/^[0-9a-f]{64}$/.test(String(f.legacyCalls[0].args.p_input_sha256)));
  assert(!JSON.stringify(f.legacyCalls).includes("private-media.invalid"));
  assertEquals(f.legacyCalls[1].args, {
    p_actor: options.actorId, p_org: options.orgId, p_key: options.key,
    p_provider_request_id: "provider-receipt",
  });
  assertEquals(result.value.id, "provider-receipt");
});

for (const [message, status] of [["RP402: Workspace processing budget reached", 402], ["RP409: This submission already started", 409], ["RP403: Your role cannot submit video", 403], ["database unavailable", 503]] as const) {
  Deno.test(`reservation refusal ${status} never calls a provider`, async () => {
    const f = fixture({ reserveError: message });
    const error = await assertRejects(() => submitReservedVideo(options, f.deps), HttpError);
    assertEquals(error.status, status);
    assertEquals(f.submissions(), 0);
    assertEquals(f.legacyCalls.length, 1);
  });
}

for (const reserve of [null, {}, { reserved: false }, "ok"]) {
  Deno.test(`malformed reservation ${JSON.stringify(reserve)} fails closed before provider`, async () => {
    const f = fixture({ reserve });
    const error = await assertRejects(() => submitReservedVideo(options, f.deps), HttpError);
    assertEquals(error.status, 503);
    assertEquals(f.submissions(), 0);
  });
}

Deno.test("lost POST acceptance retains hold and never falls over to the second eligible step", async () => {
  const f = fixture({ submitError: true });
  await assertRejects(() => submitReservedVideo({ ...options, steps: [step, { ...step, provider: "kie" }] }, f.deps), VideoDispatchUnconfirmed);
  assertEquals(f.submissions(), 1);
  assertEquals(f.legacyCalls.map((c) => c.name), ["app_video_cost_reserve_v2"]);
});

Deno.test("unusable provider receipt cannot settle or release its hold", async () => {
  const f = fixture({ wrongReceipt: true });
  await assertRejects(() => submitReservedVideo(options, f.deps), VideoDispatchUnconfirmed);
  assertEquals(f.legacyCalls.length, 1);
});

for (const failure of ["settleError", "settleThrow"] as const) {
  Deno.test(`${failure} preserves accepted receipt and never releases its hold`, async () => {
    const f = fixture({ [failure]: true });
    const result = await submitReservedVideo(options, f.deps);
    assertEquals(result.value.id, "provider-receipt");
    assertEquals(f.submissions(), 1);
    assertEquals(f.legacyCalls.length, 2);
    assert(f.legacyCalls.every((c) => !/release|refund/.test(c.name)));
  });
}

Deno.test("frame-scaled Topaz price persists in both hold and estimated ledger parameters", async () => {
  const f = fixture();
  await submitReservedVideo({ ...options, seconds: 150, unitCentsOverride: () => 32, minHoldCents: 4800 }, f.deps);
  assertEquals(f.legacyCalls[0].args.p_units, 150);
  assertEquals(f.legacyCalls[0].args.p_unit_cost_cents, 32);
  assertEquals(f.legacyCalls[0].args.p_hold_cents, 4800);
  assertEquals((f.legacyCalls[0].args.p_meta as Record<string, unknown>).price_estimated, true);
});

Deno.test("aerial flat-call pricing and reel fractional per-second pricing keep measured units", async () => {
  for (const [unit, price, seconds, total, expectedUnits] of [["call", 80, 8, 80, 1], ["second", 4.8, 5, 24, 5]] as const) {
    const f = fixture();
    await submitReservedVideo({ ...options, feature: "aerial", seconds, steps: [{ ...step, unit, unit_cents: price }] }, f.deps);
    assertEquals(f.legacyCalls[0].args.p_hold_cents, total);
    assertEquals(f.legacyCalls[0].args.p_units, expectedUnits);
  }
});

Deno.test("unpriced, unsupported or non-finite routes never reserve or POST", async () => {
  for (const change of [{ unit: "world" }, { unit_cents: 0 }, { unit_cents: NaN }, { unit_cents: Infinity }]) {
    const f = fixture();
    const error = await assertRejects(() => submitReservedVideo({ ...options, steps: [{ ...step, ...change }] }, f.deps), HttpError);
    assertEquals(error.status, 503);
    assertEquals(f.legacyCalls.length, 0);
    assertEquals(f.submissions(), 0);
  }
});
