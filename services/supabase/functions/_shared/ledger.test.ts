// ledger.test.ts — the app-AI ledger write stays best-effort, and a failed
// write leaves the one structured line the holds_unledgered admin alert
// points operators at ("Check the function logs for cost_ledger insert
// failures"). No database: the service client is a stub.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ledgerInsertFailure, recordAppAiCost, recordRoutedAiCost } from "./ledger.ts";

const ORG = "de770103-0000-4000-8000-000000000001";

function admin(outcome: { error?: { code?: string; message: string } } | "throw") {
  const inserted: Record<string, unknown>[] = [];
  const client = {
    from: (table: string) => ({
      insert: (row: Record<string, unknown>) => {
        assertEquals(table, "cost_ledger");
        inserted.push(row);
        if (outcome === "throw") return Promise.reject(new Error("socket hang up"));
        return Promise.resolve({ data: null, error: outcome.error ?? null });
      },
    }),
  };
  // deno-lint-ignore no-explicit-any
  return { client: client as any, inserted };
}

function captureErrors(): { lines: string[]; restore: () => void } {
  const real = console.error;
  const lines: string[] = [];
  console.error = (...args: unknown[]) => { lines.push(args.map((a) => typeof a === "string" ? a : JSON.stringify(a)).join(" ")); };
  return { lines, restore: () => { console.error = real; } };
}

function structured(lines: string[]): Record<string, unknown>[] {
  return lines.filter((line) => line.startsWith("{")).map((line) => JSON.parse(line) as Record<string, unknown>)
    .filter((entry) => entry.event === "cost_ledger_insert_failed");
}

const args = {
  orgId: ORG, provider: "gemini", feature: "photo_edit", model: "gemini-3.1-flash-image", unitCents: 3.9,
  meta: { request_key: "owned-photo-0001-private-suffix", stage: "photo.custom", route_id: "route-photo-1", prompt: "never logged" },
};

Deno.test("a failed cost_ledger insert is swallowed and leaves one correlatable structured line", async () => {
  const errors = captureErrors();
  try {
    const { client, inserted } = admin({ error: { code: "42501", message: "permission denied for table cost_ledger" } });
    const result = await recordAppAiCost(client, args);
    assertEquals(result, { recorded: false, total_cents: 3.9, reason: "permission denied for table cost_ledger" });
    assertEquals(inserted.length, 1);
    const lines = structured(errors.lines);
    assertEquals(lines.length, 1);
    assertEquals(lines[0], {
      event: "cost_ledger_insert_failed", request_key_prefix: "owned-ph", stage: "photo.custom", route_id: "route-photo-1",
      feature: "photo_edit", provider: "gemini", model: "gemini-3.1-flash-image", code: "42501", message: "permission denied for table cost_ledger",
    });
    // The full request key and the request's own text never reach the log line.
    const raw = errors.lines.join("\n");
    assert(!raw.includes("private-suffix")); assert(!raw.includes("never logged"));
  } finally { errors.restore(); }
});

Deno.test("a thrown insert is swallowed with the same structured line and no rethrow", async () => {
  const errors = captureErrors();
  try {
    const result = await recordAppAiCost(admin("throw").client, args);
    assertEquals(result.recorded, false); assertEquals(result.reason, "socket hang up");
    const lines = structured(errors.lines);
    assertEquals(lines.length, 1); assertEquals(lines[0].code, "exception"); assertEquals(lines[0].stage, "photo.custom");
  } finally { errors.restore(); }
});

Deno.test("a successful insert and a missing org write no failure line, and the routed wrapper carries route_id and stage", async () => {
  const errors = captureErrors();
  try {
    const ok = admin({});
    assertEquals(await recordAppAiCost(ok.client, args), { recorded: true, total_cents: 3.9 });
    assertEquals(structured(errors.lines).length, 0);
    assertEquals((await recordAppAiCost(ok.client, { ...args, orgId: "" })).recorded, false);
    assertEquals(structured(errors.lines).length, 0);
    const failing = admin({ error: { code: "23502", message: "null value in column" } });
    const routed = await recordRoutedAiCost(failing.client, {
      orgId: ORG, feature: "photo_edit", images: 1,
      step: { route_id: "route-photo-2", task: "photo.custom", provider: "fal", model: "flux-pro/kontext", unit: "image", unit_cents: 4 },
      meta: { request_key: "abcdefgh-ijkl", stage: "photo.custom" },
    });
    assertEquals(routed.recorded, false);
    const lines = structured(errors.lines);
    assertEquals(lines.length, 1);
    assertEquals(lines[0].route_id, "route-photo-2"); assertEquals(lines[0].provider, "fal"); assertEquals(lines[0].request_key_prefix, "abcdefgh"); assertEquals(lines[0].code, "23502");
  } finally { errors.restore(); }
});

Deno.test("ledgerInsertFailure bounds every field and tolerates missing meta", () => {
  const line = ledgerInsertFailure({ feature: "reel", provider: "fal", model: null }, undefined, "x".repeat(500));
  assertEquals(line.request_key_prefix, null); assertEquals(line.stage, null); assertEquals(line.code, "unknown");
  assertEquals(line.message?.length, 200); assertEquals(line.model, null);
  assertEquals(ledgerInsertFailure({ feature: "reel", provider: "fal", meta: { request_key: 42, stage: "" } }, 500, "m").code, "500");
});
