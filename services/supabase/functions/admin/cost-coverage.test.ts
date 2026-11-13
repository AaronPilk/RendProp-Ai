// Compile the actual read-only coverage function with closed count-query stubs.
// No Auth, supplier or database call and no imported production module startup.
function assert(ok: unknown, message = "assertion failed"): asserts ok { if (!ok) throw new Error(message); }
function equal(actual: unknown, expected: unknown) { assert(JSON.stringify(actual) === JSON.stringify(expected), `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`); }
async function coverage(app: {count?: number; error?: unknown}, delivery: {count?: number; error?: unknown}) {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const start = source.indexOf("interface CoverageSource {"), end = source.indexOf("// ── GET /admin/providers", start);
  assert(start > 0 && end > start, "actual coverage function missing");
  const block = source.slice(start, end).replace("async function buildCoverage(", "export async function buildCoverage(");
  const url = "data:application/typescript;base64," + btoa(unescape(encodeURIComponent("type SupabaseClient = any;\n" + block)));
  const mod = await import(url); const queries: string[] = [];
  const db = {from(table: string) { equal(table, "cost_ledger"); return {select(column: string, options: unknown) {
    equal(column, "id"); equal(options, {count: "exact", head: true});
    return {is(key: string, value: unknown) { equal([key, value], ["job_id", null]); queries.push("app"); return Promise.resolve(app); },
      eq(key: string, value: unknown) { equal([key, value], ["feature", "stream_deliver"]); queries.push("delivery"); return Promise.resolve(delivery); }};
  }}; }};
  const result = await mod.buildCoverage(db); equal(queries.sort(), ["app", "delivery"]); return result;
}
Deno.test("two populated ledger categories cannot prove whole-app supplier-cost completeness", async () => {
  const result = await coverage({count: 1, error: null}, {count: 1, error: null});
  equal(result.complete, false);
  assert(result.headline.includes("Incomplete"));
  const sources = result.sources as {key: string; represented: boolean; detail: string}[];
  assert(sources.some(s => s.key === "unmetered_external_usage" && !s.represented));
  assert(sources.some(s => s.key === "supplier_reconciliation" && !s.represented));
  assert(!JSON.stringify(result).includes("total is complete"));
});
Deno.test("ledger presence and failed reads stay distinct; counts match explicit gaps", async () => {
  for (const [app, delivery] of [[{count: 0}, {count: 0}], [{count: 999, error: {message: "fixture unavailable"}}, {count: 1}], [{count: 1}, {count: 999, error: {message: "fixture unavailable"}}]]) {
    const result = await coverage(app, delivery);
    const sources = result.sources as {key: string; represented: boolean}[];
    equal(result.complete, false);
    equal(result.represented_count, sources.filter(s => s.represented).length);
    equal(result.missing_count, sources.filter(s => !s.represented).length);
    equal(sources.find(s => s.key === "app_api_ledger")?.represented, !app.error && (app.count ?? 0) > 0);
    equal(sources.find(s => s.key === "stream_delivery")?.represented, !delivery.error && (delivery.count ?? 0) > 0);
    assert(!JSON.stringify(result).includes("fixture unavailable"));
  }
});
Deno.test("populated receipts remain estimates and do not claim every photo or video was recorded", async () => {
  const result = await coverage({count: 10}, {count: 20});
  const text = JSON.stringify(result);
  assert(text.includes("estimate")); assert(text.includes("invoice"));
  assert(!text.includes("app_ai_photo")); assert(!text.includes("app_ai_video"));
  assert(!text.includes("real provider spend is HIGHER"));
});
