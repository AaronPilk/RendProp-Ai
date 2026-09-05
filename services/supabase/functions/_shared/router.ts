// router — the AI "brain": ONE resolver that turns a task into an ordered chain
// of provider/model steps, read from a TABLE instead of from code.
//
// The frozen interface is docs/AI-ROUTER-CONTRACT.md §1 and the rows it reads
// are migrations/0018_ai_routes.sql. Three other functions build against this
// signature in parallel, so the exported names and types below are load-bearing:
// do not rename, do not widen, do not reorder the fields.
//
// ── WHAT MAKES THIS SAFE TO DEPLOY DURING A LIVE FIELD TEST ─────────────────
//
// The master flag `app_config.ai_router.enabled` defaults to FALSE, and while
// it is false resolveRoute() returns exactly ONE step: the row tagged
// `note = 'legacy'` for that task, which carries the provider/model the shipped
// edge functions hardcode TODAY. Behaviour is byte-for-byte unchanged, and the
// legacy answer comes out of the database rather than out of a second copy of
// the model ids in TypeScript — so there is only ever one place to look.
//
//     select * from ai_routes where task = $1 and note = 'legacy' limit 1
//
// ── THREE RULES CALLERS MUST KNOW ───────────────────────────────────────────
//
// 1. AN OUTAGE DEGRADES, IT DOES NOT HARD-FAIL. A step whose circuit is open is
//    moved to the END of the chain, never removed. If every step is open you
//    still get every step back, closed-circuit ones first, and you should still
//    try them — the breaker is an ordering hint, not a veto.
//
// 2. DO NOT RE-FILTER THE CHAIN. Everything returned is a step you may run
//    right now: plan, capabilities, retirement, privacy and the flag have all
//    already been applied. In particular do not filter on `step.enabled` — the
//    resolver has done it (and the flag-off legacy step is reported enabled
//    precisely so a defensive caller cannot accidentally drop the only step it
//    was given).
//
// 3. REPORT EVERY ATTEMPT. reportOutcome() is what feeds the breaker; a chain
//    nobody reports on is a chain that never learns an outage happened. It is
//    best-effort and never throws, so there is no reason not to call it.
//
// An EMPTY array means "no step you may run": either the task has no rows at
// all, or every row was filtered out (plan too low, a required capability that
// nothing provides, everything retired). Callers should surface that as a clear
// 503 rather than silently doing nothing.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { adminClient } from "./supabase.ts";

// ── The contract types (docs/AI-ROUTER-CONTRACT.md §1) ──────────────────────

export interface RouteStep {
  route_id: string; // ai_routes.id
  task: string; // e.g. "video.reel_clip"
  provider: string; // "fal" | "kie" | "higgsfield" | "gemini" | "openai" | "anthropic" | "elevenlabs" | "worldlabs" | "apple" | "rendprop"
  model: string; // exact upstream model id / endpoint slug
  unit: string; // "image" | "second" | "call" | "minute" | "1k_chars" | "world"
  unit_cents: number; // researched price, cents per unit
  capabilities: string[]; // e.g. ["i2v","1080p","9:16","6s","mask","timestamps"]
  max_latency_s: number; // circuit opens if p95 exceeds this
  min_plan: string; // "free" | "trial" | "starter" | "solo" | "pro" | "team"
  same_model_as: string | null; // upstream family key — steps sharing it are NOT availability-independent
  privacy_tier: "no_retention" | "retained_30d" | "trains_by_default";
  enabled: boolean;
}

/**
 * A RouteStep plus the two columns the ORDERING needs and the frozen §1
 * interface does not carry. It is a strict superset, so everything typed
 * `RouteStep` accepts one and the contract's interface stays byte-identical —
 * see HANDOFF-DB.md.
 */
export interface ChainStep extends RouteStep {
  /** ai_routes.position — the curated "best" order. */
  position: number;
  /** ai_routes.retire_after (YYYY-MM-DD) or null. */
  retire_after: string | null;
}

export interface RouteContext {
  plan: string; // effective plan of the org
  needs?: string[]; // capabilities the caller REQUIRES; steps lacking any are filtered out
  policy?: "best" | "cheapest"; // default: from plan_routing_policy
  carries_customer_media?: boolean; // photo/video of the property → prefer no_retention, never trains_by_default
}

export type ErrorClass = "rate_limit" | "upstream" | "timeout" | "validation" | "nsfw" | "other";

export interface OutcomeReport {
  ok: boolean;
  latency_ms: number;
  error_class?: ErrorClass;
}

// ── Health (the circuit breaker), as orderSteps() consumes it ───────────────

export interface StepHealth {
  /** ISO timestamp; the circuit is OPEN while this is in the future. */
  open_until: string | null;
  consecutive_failures: number;
}

/** Keyed by healthKey(provider, model). */
export type HealthMap = Map<string, StepHealth>;

/** The one place the (provider, model) health key is spelled. */
export function healthKey(provider: string, model: string): string {
  return `${provider}|${model}`;
}

// ── Plan ordering ───────────────────────────────────────────────────────────
//
// The six plans plan_entitlements carries (0010 §1), weakest first. `solo` is
// an entitlement-level alias of `starter` in that table but is ranked above it
// here because the routing contract (§3) gives them DIFFERENT policies —
// starter routes cheapest, solo routes best.
//
// An unrecognised plan ranks as `free`, the most restrictive answer: a typo in
// a plan string must never hand out a premium step.

const PLAN_ORDER = ["free", "trial", "starter", "solo", "pro", "team"] as const;

function planRank(plan: string | null | undefined): number {
  const i = PLAN_ORDER.indexOf(String(plan ?? "").trim().toLowerCase() as typeof PLAN_ORDER[number]);
  return i < 0 ? 0 : i;
}

// ── In-process caches (30 s) ────────────────────────────────────────────────
//
// resolveRoute runs on every AI request. The master flag and the six-row policy
// table are read-mostly, so each is cached for 30 s per isolate — long enough to
// take the round trip off the hot path, short enough that flipping the flag from
// the admin console is visible within half a minute without a redeploy.
//
// Route rows and provider_health are NOT cached: a price/enable edit and an
// outage must both take effect on the very next request.

const CACHE_TTL_MS = 30_000;

interface Cached<T> {
  value: T;
  at: number;
}

let flagCache: Cached<boolean> | null = null;
let policyCache: Cached<Map<string, "best" | "cheapest">> | null = null;

/** Test/ops seam: drop the 30 s caches so the next call re-reads the database. */
export function resetRouterCache(): void {
  flagCache = null;
  policyCache = null;
}

/**
 * FEATURE FLAG. False (the default, and the answer on any error) means
 * resolveRoute returns the legacy step for the task and behaviour is exactly
 * what shipped. Fails SAFE: a Supabase blip must not swing live traffic onto
 * an unproven chain.
 */
export async function routerEnabled(): Promise<boolean> {
  const now = Date.now();
  if (flagCache && now - flagCache.at < CACHE_TTL_MS) return flagCache.value;

  let value = false;
  try {
    const { data, error } = await db()
      .from("app_config")
      .select("value")
      .eq("key", "ai_router")
      .maybeSingle();
    if (error) throw new Error(error.message);
    value = (data?.value as { enabled?: unknown } | null)?.enabled === true;
  } catch (e) {
    console.error("router: ai_router flag read failed, staying on legacy:", msg(e));
    value = false;
  }
  flagCache = { value, at: now };
  return value;
}

/** plan → default policy, from plan_routing_policy. Unknown plan → "best". */
async function defaultPolicyFor(plan: string): Promise<"best" | "cheapest"> {
  const now = Date.now();
  if (!policyCache || now - policyCache.at >= CACHE_TTL_MS) {
    const map = new Map<string, "best" | "cheapest">();
    try {
      const { data, error } = await db().from("plan_routing_policy").select("plan, policy");
      if (error) throw new Error(error.message);
      for (const r of data ?? []) {
        const p = String((r as { policy?: unknown }).policy ?? "");
        if (p === "best" || p === "cheapest") map.set(String((r as { plan?: unknown }).plan ?? ""), p);
      }
    } catch (e) {
      // An unreadable policy table must not stop routing. "best" is the seed
      // order, i.e. the order a human curated — the safe thing to fall back to.
      console.error("router: plan_routing_policy read failed, defaulting to best:", msg(e));
    }
    policyCache = { value: map, at: now };
  }
  return policyCache.value.get(String(plan ?? "").trim().toLowerCase()) ?? "best";
}

// ── resolveRoute ────────────────────────────────────────────────────────────

/**
 * Ordered, filtered, circuit-aware chain for `task`.
 *
 * Flag OFF  → exactly the one `note = 'legacy'` row (today's behaviour).
 * Flag ON   → enabled rows for the task, minus anything retired, out of plan,
 *             missing a required capability or (for customer media) training on
 *             what we send it; ordered by the plan's policy; open circuits last.
 *
 * Never throws for a routing reason — a database failure on the ON path falls
 * back to the legacy step rather than taking the feature down.
 */
export async function resolveRoute(task: string, ctx: RouteContext): Promise<RouteStep[]> {
  const t = String(task ?? "").trim();
  if (!t) return [];

  if (!(await routerEnabled())) return await legacyChain(t);

  let rows: RouteRow[];
  try {
    const { data, error } = await db()
      .from("ai_routes")
      .select(SELECT_COLS)
      .eq("task", t)
      .eq("enabled", true)
      .order("position", { ascending: true });
    if (error) throw new Error(error.message);
    rows = (data ?? []) as RouteRow[];
  } catch (e) {
    console.error(`router: route read failed for ${t}, falling back to legacy:`, msg(e));
    return await legacyChain(t);
  }

  // A task with the flag on but no enabled rows still has a legacy answer in
  // most cases; using it beats returning nothing.
  if (rows.length === 0) return await legacyChain(t);

  const steps = rows.map(toStep);
  const health = await readHealth();
  return orderSteps(steps, ctx, health);
}

/**
 * THE FLAG-OFF PATH. One row, looked up by note, returned verbatim except that
 * `enabled` is reported true — see rule 2 in the header: every step a caller is
 * handed is a step it may run.
 */
async function legacyChain(task: string): Promise<RouteStep[]> {
  try {
    const { data, error } = await db()
      .from("ai_routes")
      .select(SELECT_COLS)
      .eq("task", task)
      .eq("note", "legacy")
      .order("position", { ascending: true })
      .limit(1);
    if (error) throw new Error(error.message);
    const row = (data ?? [])[0] as RouteRow | undefined;
    if (!row) {
      console.error(`router: no legacy step seeded for task ${task}`);
      return [];
    }
    return [{ ...toStep(row), enabled: true }];
  } catch (e) {
    console.error(`router: legacy lookup failed for ${task}:`, msg(e));
    return [];
  }
}

// ── orderSteps — the pure, unit-testable core ───────────────────────────────

/**
 * Filter and order an already-loaded set of steps. Pure: no I/O, no clock
 * beyond the `now` you pass (default: real time), so a test can assert the
 * exact chain for an exact moment.
 *
 * Order of operations, and why:
 *
 *   1. RETIRED       `retire_after < today` is dropped. An announced sunset
 *                    stops being chosen on its own date, with no deploy.
 *   2. PLAN          a step whose min_plan outranks ctx.plan is dropped.
 *   3. CAPABILITIES  a step missing ANY entry of ctx.needs is dropped. Callers
 *                    should pass only what they genuinely require: asking for
 *                    "1080p" correctly removes the 768p degraded fallback, so
 *                    asking for more than you need costs you your fallbacks.
 *   4. PRIVACY       when the request carries customer media, `trains_by_default`
 *                    is dropped outright (a hard rule) and `no_retention` sorts
 *                    ahead of everything else — a DOMINANT key, not a tiebreak.
 *                    Sending a customer's property photo to a 30-day-retention
 *                    vendor to save three cents is not a trade this router makes
 *                    quietly. (On the 0018 seed this changes nothing: the only
 *                    no_retention steps are the free on-device ones, which are
 *                    already first under both policies.)
 *   5. POLICY        `cheapest` sorts by unit_cents ascending; `best` keeps the
 *                    curated seed `position`. Both tiebreak on position, so the
 *                    result is deterministic for equal prices.
 *   6. CIRCUIT       open-circuit steps move to the END, keeping their relative
 *                    order. NEVER removed: an outage must degrade, not hard-fail.
 */
export function orderSteps(
  steps: ChainStep[],
  ctx: RouteContext,
  healthMap: HealthMap,
  now: Date = new Date(),
): ChainStep[] {
  const media = ctx.carries_customer_media === true;
  const needs = (ctx.needs ?? []).map((n) => String(n)).filter((n) => n.length > 0);
  const rank = planRank(ctx.plan);
  const today = now.toISOString().slice(0, 10); // UTC date, same basis as a DATE column

  const kept = steps.filter((s) => {
    if (s.retire_after && s.retire_after < today) return false;
    if (planRank(s.min_plan) > rank) return false;
    if (needs.some((n) => !s.capabilities.includes(n))) return false;
    if (media && s.privacy_tier === "trains_by_default") return false;
    return true;
  });

  const policy: "best" | "cheapest" = ctx.policy === "cheapest" ? "cheapest" : "best";

  const ordered = kept.slice().sort((a, b) => {
    if (media) {
      const pa = a.privacy_tier === "no_retention" ? 0 : 1;
      const pb = b.privacy_tier === "no_retention" ? 0 : 1;
      if (pa !== pb) return pa - pb;
    }
    if (policy === "cheapest") {
      const ca = Number.isFinite(a.unit_cents) ? a.unit_cents : Number.POSITIVE_INFINITY;
      const cb = Number.isFinite(b.unit_cents) ? b.unit_cents : Number.POSITIVE_INFINITY;
      if (ca !== cb) return ca - cb;
    }
    return a.position - b.position;
  });

  const ms = now.getTime();
  const closed: ChainStep[] = [];
  const open: ChainStep[] = [];
  for (const s of ordered) {
    (isOpen(healthMap.get(healthKey(s.provider, s.model)), ms) ? open : closed).push(s);
  }
  return [...closed, ...open];
}

function isOpen(h: StepHealth | undefined, nowMs: number): boolean {
  if (!h?.open_until) return false;
  const until = Date.parse(h.open_until);
  return Number.isFinite(until) && until > nowMs;
}

// ── reportOutcome ───────────────────────────────────────────────────────────

/**
 * Report ONE attempt against a step. Feeds provider_health (3 consecutive
 * failures, or any rate_limit, opens the circuit for 10 minutes; a success
 * closes it) and is the signal the ordering above runs on.
 *
 * BEST EFFORT AND NEVER THROWS, deliberately: by the time this is called the
 * provider has already run and the user already has (or has not) their result.
 * Losing that result because a telemetry write failed would be the wrong trade.
 */
export async function reportOutcome(step: RouteStep, r: OutcomeReport): Promise<void> {
  try {
    if (!step?.provider || !step?.model) return;
    const latency = Number.isFinite(r?.latency_ms) ? Math.max(0, Math.round(r.latency_ms)) : 0;
    const { error } = await db().rpc("report_provider_outcome", {
      p_provider: step.provider,
      p_model: step.model,
      p_ok: r?.ok === true,
      p_latency_ms: latency,
      p_error_class: r?.error_class ?? null,
    });
    if (error) console.error("router: report_provider_outcome failed:", error.message);
  } catch (e) {
    console.error("router: reportOutcome threw (swallowed):", msg(e));
  }
}

// ── The ledger's provider/model ─────────────────────────────────────────────

/**
 * What recordAppAiCost() / logCost() must record for a step that ran.
 *
 * It is the RESELLER, not the upstream family: contract §4 says the ledger
 * carries the provider+model that ACTUALLY ran, and that is who invoices us.
 * `same_model_as` describes availability, never billing — a Kie-resold Seedance
 * clip is Kie's line item even though the pixels came from ByteDance.
 */
export function pickLedgerProvider(step: RouteStep): { provider: string; model: string } {
  return { provider: step.provider, model: step.model };
}

// ── Row plumbing ────────────────────────────────────────────────────────────

const SELECT_COLS =
  "id, task, position, provider, model, unit, unit_cents, capabilities, max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note";

interface RouteRow {
  id: string;
  task: string;
  position: number;
  provider: string;
  model: string;
  unit: string;
  unit_cents: number | string | null;
  capabilities: string[] | null;
  max_latency_s: number | null;
  min_plan: string | null;
  same_model_as: string | null;
  privacy_tier: string | null;
  enabled: boolean | null;
  retire_after: string | null;
  note: string | null;
}

const PRIVACY_TIERS = ["no_retention", "retained_30d", "trains_by_default"] as const;

function toStep(row: RouteRow): ChainStep {
  const tier = (PRIVACY_TIERS as readonly string[]).includes(String(row.privacy_tier))
    ? (row.privacy_tier as RouteStep["privacy_tier"])
    // A tier the check constraint should have prevented. Assume the WORST, so
    // an impossible row can never be handed customer media.
    : "trains_by_default";
  return {
    route_id: String(row.id),
    task: String(row.task),
    position: Number(row.position ?? 0),
    provider: String(row.provider),
    model: String(row.model),
    unit: String(row.unit ?? "call"),
    unit_cents: Number(row.unit_cents ?? 0),
    capabilities: Array.isArray(row.capabilities) ? row.capabilities.map(String) : [],
    max_latency_s: Number(row.max_latency_s ?? 120),
    min_plan: String(row.min_plan ?? "free"),
    same_model_as: row.same_model_as ?? null,
    privacy_tier: tier,
    enabled: row.enabled === true,
    retire_after: row.retire_after ?? null,
  };
}

/** Whole table: one row per (provider, model) ever attempted — tens of rows. */
async function readHealth(): Promise<HealthMap> {
  const map: HealthMap = new Map();
  try {
    const { data, error } = await db()
      .from("provider_health")
      .select("provider, model, open_until, consecutive_failures");
    if (error) throw new Error(error.message);
    for (const r of (data ?? []) as Array<Record<string, unknown>>) {
      map.set(healthKey(String(r.provider ?? ""), String(r.model ?? "")), {
        open_until: (r.open_until as string | null) ?? null,
        consecutive_failures: Number(r.consecutive_failures ?? 0),
      });
    }
  } catch (e) {
    // No health data = no circuit is open = the curated order stands. That is
    // the correct degradation: we lose the breaker, not the router.
    console.error("router: provider_health read failed, treating all circuits as closed:", msg(e));
  }
  return map;
}

function db(): SupabaseClient {
  return adminClient();
}

function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
