// Closed tests for the /admin/spend aggregation rules. No Auth, database,
// supplier or network. The last test binds index.ts to this module so the
// rules cannot pass here while the route still sums the ledger alone.
import { aggregateLedger, recordedCents, summarizeUnreconciled } from "./spend-summary.ts";

function assert(ok: unknown, message = "assertion failed"): asserts ok {
  if (!ok) throw new Error(message);
}
function equal(actual: unknown, expected: unknown, label = "") {
  assert(JSON.stringify(actual) === JSON.stringify(expected), `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

const TEAM = "11111111-1111-4111-8111-111111111111";
const MEMBER = "22222222-2222-4222-8222-222222222222";
const SOLO = "33333333-3333-4333-8333-333333333333";
const at = "2026-10-16T12:00:00.000Z";

Deno.test("billing attribution follows billing_org_id while by_org keeps the workspace view", () => {
  const agg = aggregateLedger([
    { id: "l1", org_id: MEMBER, billing_org_id: TEAM, provider: "gemini", feature: "photo_edit", model: "m", total_cents: "3.9", created_at: at },
    { id: "l2", org_id: SOLO, billing_org_id: SOLO, provider: "fal", feature: "reel", model: "m", total_cents: 42, created_at: at },
    // Anonymised deleted-account row: org_id nulled, billing_org_id retained.
    { id: "l3", org_id: null, billing_org_id: SOLO, provider: "openai", feature: "coach", model: "m", total_cents: "2.1", created_at: at },
    // Legacy row from before billing_org_id existed.
    { id: "l4", org_id: SOLO, billing_org_id: null, provider: "fal", feature: "reel", model: "m", total_cents: 1, created_at: at },
  ]);
  equal(agg.total, 49);
  equal(agg.byOrg.get(MEMBER), { total: 3.9, rows: 1 }, "workspace bucket");
  equal(agg.byOrg.get(""), { total: 2.1, rows: 1 }, "workspace-unattributed");
  equal(agg.byBillingOrg.get(TEAM), { total: 3.9, rows: 1 }, "team pays for the member library");
  equal(agg.byBillingOrg.get(SOLO), { total: 45.1, rows: 3 }, "anonymised row still attributes to its billing account");
  equal(agg.byBillingOrg.get(MEMBER), undefined, "member library is not a paying account here");
  equal(agg.byBillingOrg.has(""), false, "legacy row falls back to org_id, not unattributed");
  equal(agg.billedElsewhereRows, 2);
  equal(agg.unreadableRows, 0);
});

Deno.test("unreadable amounts are skipped and counted, never treated as zero", () => {
  const agg = aggregateLedger([
    { id: "l1", org_id: SOLO, provider: "fal", feature: "reel", model: "m", total_cents: "NaN", created_at: at },
    { id: "l2", org_id: SOLO, provider: "fal", feature: "reel", model: "m", total_cents: null, created_at: at },
    { id: "l3", org_id: SOLO, provider: "fal", feature: "reel", model: "m", total_cents: "0.0001", created_at: at },
  ]);
  equal(agg.total, 0.0001);
  equal(agg.unreadableRows, 2);
  equal(agg.byProvider.get("fal")?.rows, 1);
  equal(recordedCents(""), null);
  equal(recordedCents("12.5"), 12.5);
  equal(recordedCents(0), 0);
});

Deno.test("ambiguous dispatch is reported as liability, not added, not priced, not zero", () => {
  const u = summarizeUnreconciled({
    serving: [
      { id: "s1", org_id: SOLO, state: "uncertain", budget_source: "ceiling", ledger_id: null, hold_cents: "30.5536", created_at: at },
      { id: "s2", org_id: SOLO, state: "reserved", budget_source: "ceiling", ledger_id: null, hold_cents: 4.8, created_at: at },
      { id: "s3", org_id: SOLO, state: "succeeded", budget_source: "ceiling", ledger_id: "l1", hold_cents: 3.9, created_at: at },
      { id: "s4", org_id: SOLO, state: "succeeded", budget_source: "funding", ledger_id: null, hold_cents: 3.9, created_at: at },
      { id: "s5", org_id: SOLO, state: "rejected", budget_source: "ceiling", ledger_id: null, hold_cents: 80, created_at: at },
    ],
    servingTruncated: false,
    video: [
      { id: "v1", hold_cents: "420", cost_ledger_id: null, released_at: null, created_at: at },
      { id: "v2", hold_cents: "420", cost_ledger_id: "l9", released_at: null, created_at: at },
      { id: "v3", hold_cents: "210", cost_ledger_id: null, released_at: at, created_at: at },
    ],
    videoTruncated: true,
    attempts: [
      { id: "a1", provider: "rentcast", outcome: "intent", estimated_cents: null, ledger_status: "not_booked", created_at: at },
      { id: "a2", provider: "rentcast", outcome: "transport_unknown", estimated_cents: null, ledger_status: "not_booked", created_at: at },
      { id: "a3", provider: "rentcast", outcome: "http_error", estimated_cents: null, ledger_status: "not_booked", created_at: at },
      { id: "a4", provider: "rentcast", outcome: "hit", estimated_cents: "7", ledger_status: "recorded", created_at: at },
      { id: "a5", provider: "rentcast", outcome: "no_record", estimated_cents: 7, ledger_status: "unconfirmed", created_at: at },
    ],
    attemptsTruncated: false,
  }) as Record<string, Record<string, unknown>>;

  const serving = u.serving_holds;
  equal(serving.open_rows_not_linked_to_ledger, 3, "uncertain + reserved + unlinked funding hold");
  equal(serving.open_hold_cents_not_linked_to_ledger, 39.2536);
  equal(serving.released_rejected_rows, 1, "rejected hold is a release, counted only");
  const groups = serving.groups as { state: string; budget_source: string; linked_to_ledger: boolean; rows: number; hold_cents: number }[];
  assert(groups.some((g) => g.state === "uncertain" && !g.linked_to_ledger && g.hold_cents === 30.5536));
  assert(groups.some((g) => g.state === "succeeded" && g.linked_to_ledger && g.rows === 1));
  assert(!groups.some((g) => g.state === "rejected"), "released hold is never listed as liability");

  const video = u.app_video_holds;
  equal(video.unsettled_rows, 1);
  equal(video.unsettled_hold_cents, 420);
  equal(video.settled_rows, 1);
  equal(video.released_rejected_rows, 1);
  equal(video.truncated, true);
  assert(String(video.detail).includes("does not prove supplier dispatch or charge"));
  assert(String(u.provider_attempts.detail).includes("does not prove supplier dispatch"));
  assert(!String(u.provider_attempts.detail).includes("dispatch started"));

  const attempts = u.provider_attempts;
  equal(attempts.by_outcome, { intent: 1, hit: 1, no_record: 1, http_error: 1, invalid_response: 0, transport_unknown: 1 });
  equal(attempts.unknown_outcome_rows, 2, "unresolved intent and lost transport are unknown");
  equal(attempts.unknown_outcome_cents, null, "unknown is null, never 0");
  equal(attempts.estimated_rows, 2);
  equal(attempts.estimated_cents, 14);
  equal(attempts.estimated_rows_not_recorded_in_ledger, 1);
  equal(attempts.estimated_cents_not_recorded_in_ledger, 7);

  const text = JSON.stringify(u);
  assert(!text.includes("total_cents\":4"), "no combined liability figure is invented");
  assert(text.includes("not added to total_cents"));
});

Deno.test("an unknown attempt outcome vocabulary is still counted as unknown", () => {
  const u = summarizeUnreconciled({
    serving: [], servingTruncated: false, video: [], videoTruncated: false,
    attempts: [{ id: "a1", provider: "rentcast", outcome: "something_new", estimated_cents: 7, ledger_status: "recorded", created_at: at }],
    attemptsTruncated: false,
  }) as Record<string, Record<string, unknown>>;
  equal(u.provider_attempts.unknown_outcome_rows, 1);
  equal(u.provider_attempts.estimated_rows, 0, "an estimate on an unrecognised outcome is not counted as consumption");
});

Deno.test("GET /admin/spend is bound to this module and reads the three liability journals", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  // The slice runs from the ledger reader through handleSpend so the three
  // journal readers it calls are bound along with the route body itself.
  const start = source.indexOf("function readLedgerSince(");
  const end = source.indexOf("// ── coverage:", start);
  assert(start > 0 && end > start && source.indexOf("async function handleSpend(", start) < end, "handleSpend missing");
  const body = source.slice(start, end);
  for (const needle of [
    "aggregateLedger(", "summarizeUnreconciled(",
    "by_billing_org", "unreconciled",
    "serving_cost_reservations", "app_video_cost_reservations", "provider_attempt_receipts",
    "billing_org_id",
  ]) {
    assert(body.includes(needle), `handleSpend does not use ${needle}`);
  }
  assert(source.includes('from "./spend-summary.ts"'), "index.ts must import the pure module");
  // The original workspace view stays for the native console contract.
  assert(body.includes("by_org:"), "by_org (workspace) must remain in the response");
});
