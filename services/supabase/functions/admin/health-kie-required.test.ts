// K3: the admin health row for KIE is optional only while the pinned Kie
// property-video route row (migration 20261016100000) is OFF. The ACTUAL
// handleHealth, healthStatus, healthProviderSpec and readKieRouteEnabled are
// compiled from index.ts with a closed database double (cost_ledger, render_jobs
// and ai_routes queries recorded in process; no Supabase, no provider call) and
// the real spend-summary bump/Bucket helpers. With the row OFF, which it is
// today, the response is byte-for-byte what it was apart from the new
// `kie_property_route_enabled` field; with the row ON, only the KIE row changes.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { KIE_PROPERTY_ROUTE_ID } from "../_shared/property-video-kie.ts";
const encode = (value: string) => { const b = new TextEncoder().encode(value); let out = ""; for (let i = 0; i < b.length; i += 32768) out += String.fromCharCode(...b.subarray(i, i + 32768)); return "data:application/typescript;base64," + btoa(out); };
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const slice = (start: string, end: string) => { const a = source.indexOf(start), b = source.indexOf(end, a + start.length); assert(a > 0 && b > a, "actual anchor: " + start); return source.slice(a, b); };
const STATUS = slice("function healthStatus(", "/**\n * Read every row a filtered query matches");
const HEALTH = slice("async function handleHealth(", "// ── GET /admin/routing");
assert(STATUS.includes("export function healthProviderSpec(") && STATUS.includes("export async function readKieRouteEnabled("), "both K3 helpers sit with healthStatus");
assert(HEALTH.includes("const kieRouteEnabled = await readKieRouteEnabled(db);") && HEALTH.includes("const specs = PROVIDERS.map((p) => healthProviderSpec(p, kieRouteEnabled));") && HEALTH.includes("kie_property_route_enabled: kieRouteEnabled,"), "handleHealth is wired to the gate");
const CONFIGURED = { FAL_KEY: "set", GEMINI_API_KEY: "set" } as Record<string, string>;
const PROVIDERS = `[
  { key: "gemini", name: "Google Gemini", kind: "ai", billable: true, credential_env: "GEMINI_API_KEY", env_names: ["GEMINI_API_KEY"], ledger_provider: "gemini", models: [] },
  { key: "fal", name: "fal.ai", kind: "ai", billable: true, credential_env: "FAL_KEY", env_names: ["FAL_KEY"], ledger_provider: "fal", models: [] },
  { key: "kie", name: "KIE.ai (one-key multi-model fallback)", kind: "ai", billable: true, optional: true, credential_env: "KIE_API_KEY", env_names: ["KIE_API_KEY"], ledger_provider: "kie", whatToDo: "Optional — expected off", models: [] },
  { key: "stream", name: "Cloudflare Stream (optional)", kind: "infra", billable: true, optional: true, credential_env: "CLOUDFLARE_STREAM_API_TOKEN", env_names: ["CLOUDFLARE_STREAM_API_TOKEN"], ledger_provider: "cloudflare", models: [] },
  { key: "render_compute", name: "Render compute", kind: "infra", billable: true, credential_env: "", env_names: [], ledger_provider: null, models: [] },
]`;
async function compile(status = STATUS, health = HEALTH) {
  return await import(encode(`
    import { HttpError, json, round4 } from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import { bump, type Bucket } from ${JSON.stringify(new URL("./spend-summary.ts", import.meta.url).href)};
    import { KIE_PROPERTY_ROUTE_ID } from ${JSON.stringify(new URL("../_shared/property-video-kie.ts", import.meta.url).href)};
    type SupabaseClient = any; type ProviderSpec = any;
    const HEALTH_WINDOW_DAYS = 7;
    const PROVIDERS: ProviderSpec[] = ${PROVIDERS};
    let env: Record<string, string> = {};
    export function setEnv(next: Record<string, string>) { env = next; }
    function envConfigured(name: string): boolean { return typeof env[name] === "string" && env[name].trim().length > 0; }
    function providerConfigured(p: ProviderSpec): boolean { return p.env_names.length === 0 ? true : p.env_names.every(envConfigured); }
    function nowIso(): string { return "2026-10-17T00:00:00.000Z"; }
    let db: any;
    export function setDb(next: any) { db = next; }
    const adminClient = () => db;
    async function pageAll(build: any, what: string) { const { data, error } = await build(0, 999); if (error) throw new HttpError(500, what + " read failed: " + error.message); return { rows: data ?? [], truncated: false }; }
    function readLedgerSince(db: any, sinceIso: string) { return pageAll((from: number, to: number) => db.from("cost_ledger").select("id, provider, total_cents").gte("created_at", sinceIso).order("id", { ascending: true }).range(from, to), "Cost ledger"); }
    ${status}
    ${health}
    export { handleHealth, healthStatus };
    // variant ${crypto.randomUUID()}
  `));
}
type Route = { enabled: boolean } | null;
/** A closed database: the ledger rows, the last row per provider, no failed render jobs, and the pinned route row. */
function database(route: Route | Error, ledger: { provider: string; total_cents: number }[] = []) {
  const queries: string[] = [];
  const table = (name: string) => {
    const filters: Record<string, unknown> = {}; let selected = "";
    // deno-lint-ignore no-explicit-any
    const q: any = {
      select: (column: string) => { selected = column; return q; },
      eq: (k: string, v: unknown) => { filters[k] = v; return q; }, gte: () => q, lt: () => q, order: () => q, limit: () => q,
      range: async () => { queries.push(`${name} range`); return { data: ledger.map((r, i) => ({ id: i + 1, ...r, feature: "reel", model: "m", created_at: "2026-10-16T00:00:00.000Z" })), error: null }; },
      maybeSingle: async () => {
        if (name === "ai_routes") { queries.push(`ai_routes ${selected} id=${filters.id}`); if (route instanceof Error) return { data: null, error: { message: route.message } }; return { data: route, error: null }; }
        queries.push(`${name} last ${filters.provider}`); const last = ledger.find((r) => r.provider === filters.provider); return { data: last ? { created_at: "2026-10-16T00:00:00.000Z", feature: "reel", model: "m" } : null, error: null };
      },
      then: (resolve: (v: unknown) => void) => { queries.push(`${name} count`); resolve({ count: 0, data: [], error: null }); },
    };
    return q;
  };
  return { queries, db: { from: table } };
}
async function health(mod: Awaited<ReturnType<typeof compile>>, route: Route | Error, env: Record<string, string>, ledger: { provider: string; total_cents: number }[] = []) {
  const d = database(route, ledger); mod.setDb(d.db); mod.setEnv(env);
  const response = await mod.handleHealth(); const body = await response.json();
  const row = (key: string) => body.providers.find((p: { key: string }) => p.key === key);
  return { status: response.status, body, queries: d.queries, kie: row("kie"), fal: row("fal"), stream: row("stream") };
}
const actual = await compile();
const strip = (body: Record<string, unknown>) => { const { generated_at: _g, kie_property_route_enabled: _k, ...rest } = body; return rest; };

Deno.test("route OFF (today): KIE stays optional_off when unset and the whole health body is what it was; the pinned row is read by its exact id", async () => {
  const off = await health(actual, { enabled: false }, CONFIGURED);
  assertEquals(off.status, 200);
  assertEquals([off.kie.optional, off.kie.configured, off.kie.status], [true, false, "optional_off"]);
  assertEquals([off.stream.optional, off.stream.status], [true, "optional_off"], "the other optional provider");
  assertEquals(off.body.kie_property_route_enabled, false);
  assert(off.queries.includes(`ai_routes enabled id=${KIE_PROPERTY_ROUTE_ID}`), off.queries.join(";"));
  // A missing row reads as OFF, never as ON.
  const missing = await health(actual, null, CONFIGURED);
  assertEquals([missing.kie.optional, missing.kie.status, missing.body.kie_property_route_enabled], [true, "optional_off", false]);
  // The reference: the same handler with the gate forced OFF produces the identical provider rows.
  const forced = await compile(STATUS.replace("if (p.key !== \"kie\" || !kieRouteEnabled) return p;", "return p;"), HEALTH);
  assertEquals(strip(off.body), strip((await health(forced, { enabled: false }, CONFIGURED)).body));
  assertEquals(strip(off.body), strip((await health(forced, { enabled: true }, CONFIGURED)).body), "the forced-off reference ignores the row");
});
Deno.test("route ON: KIE becomes required (unconfigured is a fault, configured-and-silent is idle, delivering is ok); every other provider row is unchanged", async () => {
  const unset = await health(actual, { enabled: true }, CONFIGURED);
  assertEquals([unset.kie.optional, unset.kie.configured, unset.kie.status], [false, false, "unconfigured"]);
  assertEquals([unset.stream.optional, unset.stream.status], [true, "optional_off"], "the other optional provider stays optional");
  assertEquals(unset.body.kie_property_route_enabled, true);
  const silent = await health(actual, { enabled: true }, { ...CONFIGURED, KIE_API_KEY: "set" });
  assertEquals([silent.kie.optional, silent.kie.configured, silent.kie.status, silent.kie.rows_in_window], [false, true, "idle", 0]);
  const delivering = await health(actual, { enabled: true }, { ...CONFIGURED, KIE_API_KEY: "set" }, [{ provider: "kie", total_cents: 167.5 }, { provider: "fal", total_cents: 210 }]);
  assertEquals([delivering.kie.status, delivering.kie.rows_in_window, delivering.kie.spend_cents_in_window, delivering.kie.last_success_detail], ["ok", 1, 167.5, "reel / m"]);
  // Control: FAL and the rest read identically with the row ON and OFF.
  const off = await health(actual, { enabled: false }, { ...CONFIGURED, KIE_API_KEY: "set" }, [{ provider: "kie", total_cents: 167.5 }, { provider: "fal", total_cents: 210 }]);
  const others = (b: { providers: { key: string }[] }) => b.providers.filter((p) => p.key !== "kie");
  assertEquals(others(delivering.body), others(off.body));
  assertEquals(delivering.fal, off.fal);
  // With the key set the row-OFF KIE row is still optional and "ok" exactly as before.
  assertEquals([off.kie.optional, off.kie.status], [true, "ok"]);
});
Deno.test("a failed route read is a 500 like every other health read, never a silent optional", async () => {
  const d = database(new Error("fixture unavailable")); actual.setDb(d.db); actual.setEnv(CONFIGURED);
  const error = await assertRejects(() => actual.handleHealth(), HttpError);
  assertEquals(error.status, 500);
  assertEquals(await actual.readKieRouteEnabled(database({ enabled: true }).db), true);
  assertEquals(await actual.readKieRouteEnabled(database({ enabled: false }).db), false);
  assertEquals(await actual.readKieRouteEnabled(database(null).db), false);
  // Only a boolean true enables: a truthy string or number is not the row's enabled.
  assertEquals(await actual.readKieRouteEnabled(database({ enabled: "true" as unknown as boolean }).db), false);
});
Deno.test("healthProviderSpec is Kie-only and gated: FAL/Gemini/keyless rows are returned as the same object; a compiled widened gate changes them", async () => {
  const fal = { key: "fal", env_names: ["FAL_KEY"], ledger_provider: "fal", optional: false };
  const kie = { key: "kie", env_names: ["KIE_API_KEY"], ledger_provider: "kie", optional: true };
  for (const enabled of [true, false]) assert(actual.healthProviderSpec(fal, enabled) === fal);
  assert(actual.healthProviderSpec(kie, false) === kie);
  const required = actual.healthProviderSpec(kie, true);
  assertEquals([required.key, required.optional, required.env_names, required.ledger_provider], ["kie", false, ["KIE_API_KEY"], "kie"]);
  assert(String(required.whatToDo).startsWith("REQUIRED"));
  assertEquals(actual.healthStatus(required, false, false), "unconfigured");
  assertEquals(actual.healthStatus(kie, false, false), "optional_off");
  const widened = await compile(STATUS.replace("if (p.key !== \"kie\" || !kieRouteEnabled) return p;", "if (!kieRouteEnabled) return p;"), HEALTH);
  const w = await health(widened, { enabled: true }, CONFIGURED);
  assertEquals([w.stream.optional, w.stream.status], [false, "unconfigured"], "control: the widened gate rewrites the other optional provider");
  assertEquals([(await health(actual, { enabled: true }, CONFIGURED)).stream.optional], [true]);
  const ungated = await compile(STATUS.replace("if (p.key !== \"kie\" || !kieRouteEnabled) return p;", "if (p.key !== \"kie\") return p;"), HEALTH);
  const u = await health(ungated, { enabled: false }, CONFIGURED);
  assertEquals(u.kie.status, "unconfigured", "control: without the row gate a disabled route already reads as a fault");
  console.log("ADMIN_HEALTH_KIE_COMPILED_CONTROLS=2");
});
