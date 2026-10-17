import { ledgerInsertFailure, recordAppAiCost } from "./ledger.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
function check(value: unknown, reason: string): asserts value { if (!value) throw new Error(reason); }
function equal(actual: unknown, expected: unknown, reason: string) { check(JSON.stringify(actual) === JSON.stringify(expected), reason); }
const HOSTILE = "diagnostic-fixture-public-marker customer@example.invalid https://private.fixture.invalid/photo?cap=never-real /private/customer.jpg";
const args = { orgId: "d1a69010-0000-4000-8000-000000000001", feature: "photo_edit", provider: "gemini", model: "fixture-model", units: 2, unitCents: 3.9, meta: { request_key: "abcdefgh-private-suffix", stage: "photo.custom", route_id: "fixture-route", prompt: HOSTILE } };
const correlation = { event: "cost_ledger_insert_failed", request_key_prefix: "abcdefgh", stage: "photo.custom", route_id: "fixture-route", feature: "photo_edit", provider: "gemini", model: "fixture-model" };
async function invoke(outcome: { error?: { code?: unknown; message: string } } | Error | string) {
  const methods = ["log", "info", "warn", "error", "debug", "trace", "dir", "table", "assert"] as const;
  const descriptors = methods.map(name => [name, Object.getOwnPropertyDescriptor(console, name)!] as const);
  const logs: { method: string; args: unknown[] }[] = [], inserted: unknown[] = [];
  for (const name of methods) Object.defineProperty(console, name, { configurable: true, writable: true, value: (...values: unknown[]) => { logs.push({ method: name, args: values }); } });
  const client = { from(table: string) { equal(table, "cost_ledger", "Exact existing table retained"); return { insert(row: unknown) { inserted.push(row); return outcome instanceof Error || typeof outcome === "string" ? Promise.reject(outcome) : Promise.resolve({ data: null, error: outcome.error ?? null }); } }; } } as unknown as SupabaseClient;
  try { return { result: await recordAppAiCost(client, args), logs, inserted }; }
  finally { for (const [name, descriptor] of descriptors) Object.defineProperty(console, name, descriptor); }
}
function safe(logs: { method: string; args: unknown[] }[], code: string) {
  const serialized = JSON.stringify(logs, (_key, value) => value instanceof Error ? { name: value.name, message: value.message, stack: value.stack } : value);
  for (const marker of ["diagnostic-fixture-public-marker", "customer@example.invalid", "private.fixture.invalid", "/private/customer.jpg", "never-real", "private-suffix"])
    check(!serialized.includes(marker), "Ledger error data reached console arguments");
  check(logs.length === 1 && logs[0]!.method === "error" && logs[0]!.args.length === 1 && typeof logs[0]!.args[0] === "string", "One correlatable closed ledger event survives");
  equal(JSON.parse(logs[0]!.args[0] as string), { ...correlation, code }, "Original intentional correlation and safe error code survive; no raw message");
}
for (const code of ["23514", "PGRST204", HOSTILE] as const) {
  Deno.test(`actual ledger database refusal ${code === HOSTILE ? "hostile-code" : code} preserves outcome while excluding echo from all console arguments`, async () => {
    const result = await invoke({ error: { code, message: HOSTILE } });
    equal(result.result, { recorded: false, total_cents: 7.8, reason: HOSTILE }, "Best-effort cost/outcome/caller reason unchanged");
    equal(result.inserted.length, 1, "No retry or second ledger write"); safe(result.logs, code === HOSTILE ? "unknown" : code);
  });
}
for (const kind of ["error", "non-error"] as const) {
  Deno.test(`actual ledger ${kind} transport refusal preserves amount and reason without console echo`, async () => {
    const result = await invoke(kind === "error" ? new TypeError(HOSTILE) : HOSTILE);
    equal(result.result, { recorded: false, total_cents: 7.8, reason: HOSTILE }, "Original swallowed outcome/caller reason unchanged");
    equal(result.inserted.length, 1, "No retry after uncertain write"); safe(result.logs, "exception");
  });
}
Deno.test("actual ledger success preserves every row field and exact amount without diagnostic", async () => {
  const result = await invoke({});
  equal(result.result, { recorded: true, total_cents: 7.8 }, "Exact success result unchanged");
  equal(result.inserted, [{ job_id: null, org_id: args.orgId, feature: args.feature, provider: args.provider, model: args.model, units: args.units, unit_cost_cents: args.unitCents, total_cents: 7.8, meta: args.meta }], "Exact persisted row and intentional metadata unchanged");
  equal(result.logs, [], "No success diagnostic added");
});
Deno.test("ledger diagnostic keeps only validated code syntax and never accepts freeform messages", () => {
  for (const code of [undefined, null, 500, "lower", "23514 " , HOSTILE]) {
    const line = ledgerInsertFailure(args, code, HOSTILE);
    equal(line, { ...correlation, code: "unknown" }, "Unknown code remains a closed classification");
    check(!JSON.stringify(line).includes(HOSTILE), "Helper output excludes database text");
  }
});
