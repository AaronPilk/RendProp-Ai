import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, respondError } from "./http.ts";

// Import the actual Auth/client module with synthetic bindings only. Every
// request is intercepted below; the test command denies real network access.
for (const [name, value] of Object.entries({
  SUPABASE_URL: "https://paid-ai-auth-fixture.invalid",
  SUPABASE_SERVICE_ROLE_KEY: "fixture-service",
  SUPABASE_ANON_KEY: "fixture-anon",
})) Deno.env.set(name, value);

const USER = "da100103-0000-4000-8000-000000000001";
const ORG = "da100103-0000-4000-8000-000000000002";
const OTHER = "da100103-0000-4000-8000-000000000003";
type Options = {
  anonymous?: unknown; authError?: boolean; source?: unknown; plan?: unknown;
  deleted?: unknown; missingOrg?: boolean; missingSubscription?: boolean;
  subscriptionOrg?: string; subscriptionUser?: string; subscriptionPlan?: string;
  subscriptionStatus?: string; expiry?: unknown; errorTable?: string;
};
type Fixture = { options: Options; calls: Request[]; meters: string[] };
let active: Fixture | null = null;
const originalFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  if (!active) throw new Error("No active synthetic fixture");
  const req = new Request(input, init), url = new URL(req.url);
  if (url.hostname !== "paid-ai-auth-fixture.invalid") throw new Error("Unmodeled network refused");
  active.calls.push(req);
  const o = active.options;
  const table = url.pathname.split("/").pop();
  const json = (value: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(value), {
    status, headers: { "content-type": "application/json" },
  }));
  const row = (value: unknown) => json(req.headers.get("accept")?.includes("vnd.pgrst.object") ? value : [value]);
  if (table === o.errorTable) return json({ message: "synthetic lookup unavailable" }, 400);
  if (url.pathname === "/auth/v1/user") return o.authError ? json({ message: "invalid token" }, 401) : json({
    id: USER, aud: "authenticated", is_anonymous: o.anonymous,
    user_metadata: { is_anonymous: false, plan: "team" },
  });
  if (table === "active_org_for_user") return json(ORG);
  if (table === "memberships") return row({ org_id: ORG, role: "owner" });
  if (table === "orgs") return row(o.missingOrg ? null : { plan_source: o.source ?? null, deleted_at: o.deleted ?? null });
  if (table === "effective_plan") return json(o.plan ?? "free");
  if (table === "apple_subscriptions") return row(o.missingSubscription ? null : {
    org_id: o.subscriptionOrg ?? ORG, user_id: o.subscriptionUser ?? USER,
    plan: o.subscriptionPlan ?? o.plan ?? "starter", status: o.subscriptionStatus ?? "active",
    expires_at: o.expiry ?? new Date(Date.now() + 86400_000).toISOString(),
  });
  throw new Error("Unmodeled synthetic database request");
};
const auth = await import("./supabase.ts");
for (const name of ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ANON_KEY"]) Deno.env.delete(name);

async function fixture<T>(options: Options, work: (f: Fixture) => Promise<T>): Promise<T> {
  assert(active === null);
  active = { options, calls: [], meters: [] };
  try { return await work(active); } finally { active = null; }
}
const request = () => new Request("https://edge-fixture.invalid/paid-ai", { headers: {
  authorization: "Bearer client-claims-do-not-authorize", "x-org-id": ORG,
  "idempotency-key": "fixture-logical-submission",
} });
async function authorize(): Promise<void> {
  const user = await auth.getUser(request());
  await auth.assertPaidAiIdentity(user, ORG);
}
async function denied(options: Options, status = 401): Promise<void> {
  await fixture(options, async () => {
    const error = await assertRejects(authorize, HttpError);
    assertEquals(error.status, status);
    const response = respondError(error);
    assertEquals(response.status, status);
    assertEquals((await response.json()).code, status === 401 ? "unauthorized" : "upstream");
  });
}

Deno.test("identified Auth user preserves free-plan AI access without subscription reads", () => fixture({ anonymous: false }, async (f) => {
  await authorize(); assertEquals(f.calls.length, 1);
}));
Deno.test("general getUser still accepts anonymous sessions for local work and adoption", () => fixture({ anonymous: true }, async (f) => {
  assertEquals((await auth.getUser(request())).is_anonymous, true); assertEquals(f.calls.length, 1);
}));
Deno.test("invalid Auth result cannot reach subscription authorization", () => denied({ authError: true }));
for (const value of [undefined, null, "false", 0]) Deno.test(`unknown Auth identity flag ${String(value)} fails closed`, () => denied({ anonymous: value }));
for (const source of [null, "trial", "manual"]) Deno.test(`anonymous ${String(source)} source cannot farm a free or legacy trial allowance`, () => denied({ anonymous: true, source, plan: "trial" }));
Deno.test("client metadata cannot turn anonymous free Auth user into a paid identity", () => denied({ anonymous: true }));
for (const plan of ["free", "trial", "brokerage", null]) Deno.test(`anonymous Apple org with effective plan ${String(plan)} is denied`, () => denied({ anonymous: true, source: "apple", plan }));
for (const status of ["active", "grace"]) Deno.test(`guest Apple ${status} subscription remains usable on its exact user and workspace`, () => fixture({ anonymous: true, source: "apple", plan: "starter", subscriptionStatus: status }, async (f) => {
  await authorize();
  const query = new URL(f.calls.find((r) => r.url.includes("apple_subscriptions"))!.url);
  assertEquals(query.searchParams.get("org_id"), "eq." + ORG);
  assertEquals(query.searchParams.get("user_id"), "eq." + USER);
  assertEquals(query.searchParams.get("plan"), "eq.starter");
  assertEquals(query.searchParams.get("status"), "in.(active,grace)");
}));
for (const patch of [
  { missingOrg: true }, { deleted: "2026-01-01T00:00:00Z" }, { missingSubscription: true },
  { subscriptionOrg: OTHER }, { subscriptionUser: OTHER }, { subscriptionPlan: "pro" },
  { subscriptionStatus: "revoked" }, { subscriptionStatus: "expired" },
  { expiry: "invalid" }, { expiry: "2020-01-01T00:00:00Z" },
]) Deno.test(`guest subscription refuses missing, revoked, expired or mismatched binding ${JSON.stringify(patch)}`, () => denied({ anonymous: true, source: "apple", plan: "starter", ...patch }));
for (const errorTable of ["orgs", "effective_plan", "apple_subscriptions"]) Deno.test(`subscription lookup ${errorTable} failure is 503 before paid dispatch`, () => denied({ anonymous: true, source: "apple", plan: "starter", errorTable }, 503));

// Compile the actual guard functions, without importing provider entrypoints.
// Only their nonauthorization dependencies are fixture boundaries. Removing the
// identity call from any source guard lets a free anonymous caller hit a meter.
const routeSpecs = [
  { route: "ai-photo", guard: "guardEdit", functions: ["requireEditorRole", "guardEdit"] },
  { route: "ai-photo", guard: "guardHelper", functions: ["requireEditorRole", "guardHelper"] },
  { route: "ai-video", guard: "guardGenerate", functions: ["capFor", "meterKeyFor", "labelFor", "guardGenerate"] },
  { route: "ai-video", guard: "guardDriftCheck", functions: ["guardDriftCheck"] },
  { route: "ai-copy", guard: "guardAssist", functions: ["guardAssist"] },
  { route: "ai-chapters", guard: "guardChapters", functions: ["guardChapters"] },
  { route: "ai-voice", guard: "guardTTS", functions: ["requireEditorRole", "guardTTS"] },
];
function functionSource(source: string, name: string): string {
  const found = source.match(new RegExp(`^(?:async )?function ${name}\\([\\s\\S]*?^}`, "m"));
  assert(found, `Missing actual ${name} source`);
  return found[0];
}
async function guardModule(spec: typeof routeSpecs[number], omitIdentity = false): Promise<Record<string, (...args: unknown[]) => Promise<unknown>>> {
  const source = await Deno.readTextFile(new URL(`../${spec.route}/index.ts`, import.meta.url));
  assert(source.includes(`${spec.guard}(user, req`), `Actual handler must pass its Auth-validated user to ${spec.guard}`);
  let functions = spec.functions.map((name) => functionSource(source, name)).join("\n");
  if (omitIdentity) functions = functions.replaceAll("await assertPaidAiIdentity(user, orgId);", "");
  const constants = [...source.matchAll(/^const ([A-Z][A-Z0-9_]+) = ([0-9 *]+);/gm)].map((m) => m[0]).join("\n");
  const program = `
    import {adminClient,orgForUser,preferredOrg,assertPaidAiIdentity,type PaidAiCaller} from ${JSON.stringify(new URL("./supabase.ts", import.meta.url).href)};
    import {HttpError} from ${JSON.stringify(new URL("./http.ts", import.meta.url).href)};
    import {quotaError} from ${JSON.stringify(new URL("./entitlements.ts", import.meta.url).href)};
    import {requiredIdempotencyKey} from ${JSON.stringify(new URL("./idempotency.ts", import.meta.url).href)};
    type EditCharge=any;type HelperCharge=any;type GenerateCharge=any;type Charge=any;type GenKind="reel"|"aerial"|"drone"|"declutter";
    const durableRateLimit = async (key:string) => { (globalThis as any).__paidAiMeter(key); return true; };
    const entitlementForCharge = async () => ({plan:"starter",renders_per_month:4,photo_edits_per_month:100,reels_per_month:6,aerials_per_month:2,topaz_per_month:1,cogs_ceiling_cents:1200});
    ${constants}\n${functions}\nexport {${spec.guard}};
  `;
  return await import("data:application/typescript," + encodeURIComponent(program));
}
Object.assign(globalThis, { __paidAiMeter: (key: string) => { assert(active); active.meters.push(key); } });
for (const spec of routeSpecs) Deno.test(`actual ${spec.route}/${spec.guard} authorizes before every paid meter and preserves guest purchases`, async () => {
  const module = await guardModule(spec);
  const invoke = async () => module[spec.guard](await auth.getUser(request()), request(), spec.guard === "guardGenerate" ? "reel" : ORG);
  await fixture({ anonymous: true }, async (f) => {
    await assertRejects(invoke, HttpError); assertEquals(f.meters, []);
  });
  await fixture({ anonymous: true, source: "apple", plan: "starter" }, async (f) => {
    await invoke(); assert(f.meters.length > 0);
  });
});
Deno.test("actual paid photo guard negative control detects a removed identity gate", async () => {
  const spec = routeSpecs[0], module = await guardModule(spec, true);
  await fixture({ anonymous: true }, async (f) => {
    await module[spec.guard](await auth.getUser(request()), request()); assert(f.meters.length > 0);
  });
});
Deno.test("actual reflection submit and paid property lookup guard before dispatch; existing job reads stay available", async () => {
  const video = await Deno.readTextFile(new URL("../ai-video/index.ts", import.meta.url));
  assert(video.includes('if (eraseAction === "submit") await assertPaidAiIdentity(user, orgId);'));
  assert(video.indexOf('if (eraseAction === "submit") await assertPaidAiIdentity(user, orgId);') < video.indexOf('return await eraseHandler(req'));
  const property = await Deno.readTextFile(new URL("../property/index.ts", import.meta.url));
  assert(property.indexOf("await assertPaidAiIdentity(user, orgId)") < property.indexOf("await provider.lookup(address)"));
  const coach = await Deno.readTextFile(new URL("../coach/index.ts", import.meta.url));
  assert(coach.indexOf("await assertPaidAiIdentity(user, orgId)") < coach.indexOf('await durableRateLimit(`coachburst:'));
});
Deno.test("restore synthetic fetch boundary", () => { globalThis.fetch = originalFetch; });
