// router.test.ts — the routing brain's decision logic, tested without a network.
//
//   deno test --allow-env --allow-net _shared/router.test.ts
//
// Two kinds of test live here:
//
//   • orderSteps() is PURE. It gets fixtures modelled on the real 0018 seed and
//     a fixed `now`, so every assertion is exact rather than approximately true.
//   • the FLAG-OFF path is the one thing that must be verified end to end,
//     because "byte-identical legacy behaviour" is the promise that makes this
//     deployable mid-field-test. It runs the real resolveRoute() against a
//     stubbed `fetch`, so the assertion covers the actual PostgREST query the
//     function builds — including that it filters on note=eq.legacy.
//
// `--allow-net` is only needed because supabase-js constructs a client; the
// stubbed fetch means no request ever leaves the process.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { ChainStep, HealthMap, RouteContext } from "./router.ts";

// supabase.ts reads its env at module load, so the env must exist BEFORE
// router.ts is evaluated — hence the dynamic import. (`import type` above is
// erased at runtime and does not trigger evaluation.)
Deno.env.set("SUPABASE_URL", "https://router-test.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key");
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");

const { orderSteps, resolveRoute, resetRouterCache, healthKey, pickLedgerProvider } = await import(
  "./router.ts"
);

const NOW = new Date("2026-09-04T12:00:00.000Z");

// ── Fixtures: the real video.aerial chain from migration 0018 ───────────────
// (dop/turbo ships enabled=false — here it is enabled so the CAPABILITY filter
// is what the test is measuring, not the enable flag.)

function step(over: Partial<ChainStep> & { provider: string; model: string }): ChainStep {
  return {
    route_id: `${over.provider}:${over.model}`,
    task: "video.aerial",
    position: 1,
    unit: "second",
    unit_cents: 0,
    capabilities: [],
    max_latency_s: 600,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
    retire_after: null,
    ...over,
  };
}

const FAL_SEEDANCE = step({
  provider: "fal",
  model: "bytedance/seedance/v1/pro/fast/image-to-video",
  position: 1,
  unit_cents: 4.86,
  capabilities: ["i2v", "1080p", "6s", "8s", "16:9", "9:16"],
  same_model_as: "bytedance/seedance-1.0-pro-fast",
});

const HF_SEEDANCE = step({
  provider: "higgsfield",
  model: "bytedance/seedance/v1/pro/fast/image-to-video",
  position: 2,
  unit_cents: 4.86,
  capabilities: ["i2v", "1080p", "6s", "8s", "16:9", "9:16"],
  same_model_as: "bytedance/seedance-1.0-pro-fast",
  privacy_tier: "trains_by_default",
});

const FAL_VEO = step({
  provider: "fal",
  model: "veo3.1/fast/image-to-video",
  position: 3,
  unit_cents: 10.0,
  capabilities: ["i2v", "1080p", "6s", "8s", "16:9", "9:16"],
  same_model_as: "google/veo-3.1-fast",
});

const HF_DOP = step({
  provider: "higgsfield",
  model: "dop/turbo",
  position: 4,
  unit_cents: 8.3,
  capabilities: ["i2v", "720p", "5s", "16:9", "9:16"], // 5s/720p ceiling — no "6s"
  privacy_tier: "trains_by_default",
});

const AERIAL: ChainStep[] = [FAL_SEEDANCE, HF_SEEDANCE, FAL_VEO, HF_DOP];

const BEST: RouteContext = { plan: "pro", policy: "best" };
const NO_HEALTH: HealthMap = new Map();

const ids = (steps: ChainStep[]) => steps.map((s) => `${s.provider}/${s.model}`);

// ── 1. FLAG OFF → exactly the legacy step, byte-identical to today ──────────

Deno.test("flag OFF returns exactly the note='legacy' step for the task", async () => {
  const seen: string[] = [];
  const realFetch = globalThis.fetch;

  const legacyRow = {
    id: "11111111-1111-1111-1111-111111111111",
    task: "photo.sky",
    position: 99,
    provider: "gemini",
    model: "gemini-2.5-flash-image",
    unit: "image",
    unit_cents: 3.9,
    capabilities: ["prompt-edit"],
    max_latency_s: 60,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: false, // it is disabled in the table…
    retire_after: null,
    note: "legacy",
  };

  globalThis.fetch = ((input: string | URL | Request, _init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    seen.push(url);
    const body = url.includes("/app_config")
      ? JSON.stringify({ value: { enabled: false } }) // the master flag, OFF
      : url.includes("/ai_routes")
      ? JSON.stringify([legacyRow])
      : "[]";
    return Promise.resolve(
      new Response(body, { status: 200, headers: { "Content-Type": "application/json" } }),
    );
  }) as typeof fetch;

  try {
    resetRouterCache();
    const chain = await resolveRoute("photo.sky", { plan: "pro", needs: ["mask"] });

    assertEquals(chain.length, 1, "flag-off must return exactly one step");
    assertEquals(chain[0].provider, "gemini");
    assertEquals(chain[0].model, "gemini-2.5-flash-image");
    assertEquals(chain[0].unit_cents, 3.9);

    // …but it is handed back ENABLED: everything resolveRoute returns is a step
    // the caller may run, so a defensive `.filter(s => s.enabled)` cannot drop
    // the only step it was given.
    assertEquals(chain[0].enabled, true);

    // The flag-off answer comes from the note='legacy' row, not from a second
    // copy of the model id in TypeScript.
    const routeQuery = seen.find((u) => u.includes("/ai_routes"));
    assert(routeQuery, "resolveRoute must query ai_routes");
    assertStringIncludes(routeQuery!, "note=eq.legacy");
    assertStringIncludes(routeQuery!, "task=eq.photo.sky");

    // ctx.needs is NOT applied on the legacy path — the legacy step is today's
    // behaviour verbatim, and today's code does no capability filtering.
    assertEquals(chain[0].capabilities, ["prompt-edit"]);
  } finally {
    globalThis.fetch = realFetch;
    resetRouterCache();
  }
});

// ── 2. needs-filter ────────────────────────────────────────────────────────

Deno.test("needs:['6s'] drops the Higgsfield DoP step (5s/720p ceiling)", () => {
  const out = orderSteps(AERIAL, { ...BEST, needs: ["6s"] }, NO_HEALTH, NOW);
  assertEquals(ids(out), [
    "fal/bytedance/seedance/v1/pro/fast/image-to-video",
    "higgsfield/bytedance/seedance/v1/pro/fast/image-to-video",
    "fal/veo3.1/fast/image-to-video",
  ]);
  assert(!ids(out).includes("higgsfield/dop/turbo"), "DoP cannot serve 6s and must be filtered out");
});

Deno.test("a need nothing advertises empties the chain (caller must 503)", () => {
  assertEquals(orderSteps(AERIAL, { ...BEST, needs: ["4k"] }, NO_HEALTH, NOW).length, 0);
});

Deno.test("no needs → every step survives, in seed order", () => {
  assertEquals(ids(orderSteps(AERIAL, BEST, NO_HEALTH, NOW)), [
    "fal/bytedance/seedance/v1/pro/fast/image-to-video",
    "higgsfield/bytedance/seedance/v1/pro/fast/image-to-video",
    "fal/veo3.1/fast/image-to-video",
    "higgsfield/dop/turbo",
  ]);
});

// ── 3. cheapest re-sorts ───────────────────────────────────────────────────

Deno.test("policy 'cheapest' re-sorts by unit_cents; 'best' keeps seed position", () => {
  const cheapest = orderSteps(AERIAL, { plan: "free", policy: "cheapest" }, NO_HEALTH, NOW);
  assertEquals(cheapest.map((s) => s.unit_cents), [4.86, 4.86, 8.3, 10.0]);

  // Equal prices keep their seed order — the sort is deterministic, not stable
  // by luck: position is the explicit tiebreak.
  assertEquals(cheapest[0].provider, "fal");
  assertEquals(cheapest[1].provider, "higgsfield");

  const best = orderSteps(AERIAL, BEST, NO_HEALTH, NOW);
  assertEquals(best.map((s) => s.position), [1, 2, 3, 4]);
});

// ── 4. customer media: never trains_by_default, no_retention first ──────────

Deno.test("carries_customer_media drops every trains_by_default step", () => {
  const out = orderSteps(AERIAL, { ...BEST, carries_customer_media: true }, NO_HEALTH, NOW);
  assertEquals(ids(out), [
    "fal/bytedance/seedance/v1/pro/fast/image-to-video",
    "fal/veo3.1/fast/image-to-video",
  ]);
  assert(
    out.every((s) => s.privacy_tier !== "trains_by_default"),
    "a property photo may never reach a vendor that trains on it by default",
  );
});

Deno.test("carries_customer_media sorts no_retention first, outranking cheapest", () => {
  const onDevice = step({
    provider: "apple",
    model: "on-device-speech",
    task: "stt.captions",
    position: 1,
    unit: "minute",
    unit_cents: 0,
    capabilities: ["stt", "word_timestamps"],
    privacy_tier: "no_retention",
  });
  const cloud = step({
    provider: "openai",
    model: "whisper-1",
    task: "stt.captions",
    position: 2,
    unit: "minute",
    unit_cents: 0.6,
    capabilities: ["stt", "word_timestamps"],
  });

  // Even with the cloud step made artificially cheaper, privacy wins.
  const cheaperCloud = { ...cloud, unit_cents: -1 };
  const out = orderSteps(
    [cheaperCloud, onDevice],
    { plan: "free", policy: "cheapest", carries_customer_media: true },
    NO_HEALTH,
    NOW,
  );
  assertEquals(out[0].provider, "apple");
});

// ── 5. the circuit breaker: LAST, never gone ───────────────────────────────

Deno.test("an open circuit moves a step to the END and never removes it", () => {
  const health: HealthMap = new Map([
    [healthKey(FAL_SEEDANCE.provider, FAL_SEEDANCE.model), {
      open_until: "2026-09-04T12:05:00.000Z", // 5 minutes into the future
      consecutive_failures: 3,
    }],
  ]);

  const out = orderSteps(AERIAL, BEST, health, NOW);
  assertEquals(out.length, 4, "an outage must degrade, not hard-fail — nothing is dropped");
  assertEquals(ids(out).at(-1), "fal/bytedance/seedance/v1/pro/fast/image-to-video");
  assertEquals(ids(out)[0], "higgsfield/bytedance/seedance/v1/pro/fast/image-to-video");
});

Deno.test("every circuit open → still every step, closed-circuit order preserved", () => {
  const openAll: HealthMap = new Map(
    AERIAL.map((s) => [healthKey(s.provider, s.model), {
      open_until: "2026-09-04T12:05:00.000Z",
      consecutive_failures: 5,
    }]),
  );
  assertEquals(ids(orderSteps(AERIAL, BEST, openAll, NOW)), ids(AERIAL));
});

Deno.test("an EXPIRED open_until is a closed circuit", () => {
  const stale: HealthMap = new Map([
    [healthKey(FAL_SEEDANCE.provider, FAL_SEEDANCE.model), {
      open_until: "2026-09-04T11:55:00.000Z", // 5 minutes ago
      consecutive_failures: 3,
    }],
  ]);
  assertEquals(ids(orderSteps(AERIAL, BEST, stale, NOW))[0], ids(AERIAL)[0]);
});

// ── 6. retirement and plan filters ─────────────────────────────────────────

Deno.test("retire_after in the past drops the step; today and later keep it", () => {
  const retired = { ...FAL_VEO, retire_after: "2026-09-03" };
  const expiringToday = { ...FAL_VEO, retire_after: "2026-09-04" };
  const future = { ...FAL_VEO, retire_after: "2027-02-26" };

  assertEquals(orderSteps([retired], BEST, NO_HEALTH, NOW).length, 0);
  assertEquals(orderSteps([expiringToday], BEST, NO_HEALTH, NOW).length, 1);
  assertEquals(orderSteps([future], BEST, NO_HEALTH, NOW).length, 1);
});

Deno.test("a step above the caller's plan is dropped; an unknown plan reads as free", () => {
  const proOnly = step({ provider: "worldlabs", model: "marble-1.1", min_plan: "pro" });
  assertEquals(orderSteps([proOnly], { plan: "pro" }, NO_HEALTH, NOW).length, 1);
  assertEquals(orderSteps([proOnly], { plan: "team" }, NO_HEALTH, NOW).length, 1);
  assertEquals(orderSteps([proOnly], { plan: "starter" }, NO_HEALTH, NOW).length, 0);
  assertEquals(orderSteps([proOnly], { plan: "solo" }, NO_HEALTH, NOW).length, 0);
  assertEquals(orderSteps([proOnly], { plan: "nonsense" }, NO_HEALTH, NOW).length, 0);
});

// ── 7. the ledger records the RESELLER, not the upstream family ────────────

Deno.test("pickLedgerProvider returns the step that actually ran", () => {
  const kie = step({
    provider: "kie",
    model: "bytedance/v1-pro-fast-image-to-video",
    same_model_as: "bytedance/seedance-1.0-pro-fast",
  });
  assertEquals(pickLedgerProvider(kie), {
    provider: "kie",
    model: "bytedance/v1-pro-fast-image-to-video",
  });
});
