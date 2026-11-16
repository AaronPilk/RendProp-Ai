// admin/spend-summary.ts — pure aggregation for GET /admin/spend.
//
// index.ts reads the rows (service role, after the admin gate) and hands them
// here. Nothing in this file touches the network, the database or the
// environment, so every rule below is exercised by spend-summary.test.ts with
// plain fixtures and no Auth, supplier or Postgres dependency.
//
// Two accounting rules this module exists to keep straight:
//
//   1. Attribution. `cost_ledger.org_id` is the WORKSPACE the call ran in.
//      `cost_ledger.billing_org_id` is the library/team that PAYS for it (the
//      z_team_billing_liability trigger stamps it; a Team member's private
//      library bills to the team org). The console's original `by_org` keeps
//      its workspace meaning for the native client; `by_billing_org` is the
//      additive paying-account view. Anonymised deleted-account rows keep
//      their billing_org_id after org_id is nulled, so they still attribute
//      to the account that owed them instead of vanishing into
//      "(unattributed)".
//
//   2. Ambiguous dispatch is not free. `total_cents` sums ledger rows only.
//      Reserved/uncertain serving holds, unsettled app-video holds and
//      unresolved or lost-transport provider attempts are potential supplier
//      liability with no ledger row. They are reported in `unreconciled`,
//      never added to `total_cents`, never priced when the journal says the
//      amount is unknown, and never netted against each other.

export interface LedgerRow {
  id: string;
  org_id: string | null;
  billing_org_id?: string | null;
  provider: string | null;
  feature: string | null;
  model: string | null;
  total_cents: number | string | null;
  created_at: string;
}

export interface ServingHoldRow {
  id: string;
  org_id: string | null;
  billing_org_id?: string | null;
  state: string | null;
  budget_source: string | null;
  ledger_id: string | null;
  hold_cents: number | string | null;
  created_at: string;
}

export interface AppVideoHoldRow {
  id: string;
  hold_cents: number | string | null;
  cost_ledger_id: string | null;
  released_at: string | null;
  created_at: string;
}

export interface ProviderAttemptRow {
  id: string;
  provider: string | null;
  outcome: string | null;
  estimated_cents: number | string | null;
  ledger_status: string | null;
  created_at: string;
}

export interface Bucket {
  total: number;
  rows: number;
}

export function round4(n: number): number {
  return Math.round(n * 10_000) / 10_000;
}

export function bump(map: Map<string, Bucket>, key: string, cents: number): void {
  const b = map.get(key) ?? { total: 0, rows: 0 };
  b.total += cents;
  b.rows += 1;
  map.set(key, b);
}

export function share(part: number, whole: number): number {
  return whole > 0 ? round4(part / whole) : 0;
}

/** A recorded amount, or null when the column is absent/NaN (never 0 by default). */
export function recordedCents(value: number | string | null | undefined): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

export interface LedgerAggregate {
  total: number;
  byProvider: Map<string, Bucket>;
  byFeature: Map<string, Bucket>;
  /** Keyed by workspace org_id; "" = unattributed. */
  byOrg: Map<string, Bucket>;
  /** Keyed by billing_org_id, falling back to org_id; "" = unattributed. */
  byBillingOrg: Map<string, Bucket>;
  /** Rows whose billing_org_id differs from org_id (team-billed member libraries, anonymised rows). */
  billedElsewhereRows: number;
  /** Rows skipped because total_cents was not a finite number. */
  unreadableRows: number;
}

export function aggregateLedger(rows: LedgerRow[]): LedgerAggregate {
  const byProvider = new Map<string, Bucket>();
  const byFeature = new Map<string, Bucket>();
  const byOrg = new Map<string, Bucket>();
  const byBillingOrg = new Map<string, Bucket>();
  let total = 0;
  let billedElsewhereRows = 0;
  let unreadableRows = 0;
  for (const r of rows) {
    const cents = recordedCents(r.total_cents);
    if (cents === null) {
      unreadableRows += 1;
      continue;
    }
    total += cents;
    bump(byProvider, r.provider ?? "unknown", cents);
    bump(byFeature, r.feature ?? "unknown", cents);
    bump(byOrg, r.org_id ?? "", cents);
    const billing = r.billing_org_id ?? r.org_id ?? "";
    bump(byBillingOrg, billing, cents);
    if ((r.billing_org_id ?? null) !== null && r.billing_org_id !== r.org_id) billedElsewhereRows += 1;
  }
  return { total: round4(total), byProvider, byFeature, byOrg, byBillingOrg, billedElsewhereRows, unreadableRows };
}

export interface UnreconciledInput {
  serving: ServingHoldRow[];
  servingTruncated: boolean;
  video: AppVideoHoldRow[];
  videoTruncated: boolean;
  attempts: ProviderAttemptRow[];
  attemptsTruncated: boolean;
}

const KNOWN_ATTEMPT_OUTCOMES = ["intent", "hit", "no_record", "http_error", "invalid_response", "transport_unknown"] as const;

/**
 * Potential liability that `total_cents` cannot see. Every number here is a
 * count or a retained hold/estimate from the journal itself; nothing is priced
 * or inferred here. `rejected` serving holds and `released_at` video holds are
 * journal-confirmed releases and are reported only as counts.
 */
export function summarizeUnreconciled(input: UnreconciledInput): Record<string, unknown> {
  // Serving holds: group by (state, budget_source, linked-to-ledger-by-id).
  const servingGroups = new Map<string, { state: string; budget_source: string; linked_to_ledger: boolean; rows: number; hold_cents: number }>();
  let servingReleasedRows = 0;
  let servingOpenHoldCents = 0;
  let servingOpenRows = 0;
  for (const h of input.serving) {
    const state = h.state ?? "unknown";
    if (state === "rejected") {
      servingReleasedRows += 1;
      continue;
    }
    const linked = typeof h.ledger_id === "string" && h.ledger_id.length > 0;
    const source = h.budget_source ?? "unknown";
    const key = `${state}|${source}|${linked ? "1" : "0"}`;
    const g = servingGroups.get(key) ?? { state, budget_source: source, linked_to_ledger: linked, rows: 0, hold_cents: 0 };
    g.rows += 1;
    g.hold_cents += recordedCents(h.hold_cents) ?? 0;
    servingGroups.set(key, g);
    if (!linked) {
      servingOpenRows += 1;
      servingOpenHoldCents += recordedCents(h.hold_cents) ?? 0;
    }
  }

  // App-video holds: unsettled = no ledger row and not released.
  let videoUnsettledRows = 0;
  let videoUnsettledHoldCents = 0;
  let videoReleasedRows = 0;
  let videoSettledRows = 0;
  for (const v of input.video) {
    if (v.cost_ledger_id) {
      videoSettledRows += 1;
      continue;
    }
    if (v.released_at) {
      videoReleasedRows += 1;
      continue;
    }
    videoUnsettledRows += 1;
    videoUnsettledHoldCents += recordedCents(v.hold_cents) ?? 0;
  }

  // Provider attempts (RentCast journal): outcome counts; estimates only where
  // the journal recorded one; unknown outcomes carry no amount at all.
  const byOutcome: Record<string, number> = {};
  for (const o of KNOWN_ATTEMPT_OUTCOMES) byOutcome[o] = 0;
  let unknownOutcomeRows = 0;
  let estimatedCents = 0;
  let estimatedRows = 0;
  let estimatedNotRecordedCents = 0;
  let estimatedNotRecordedRows = 0;
  for (const a of input.attempts) {
    const outcome = a.outcome ?? "unknown";
    byOutcome[outcome] = (byOutcome[outcome] ?? 0) + 1;
    if (outcome === "intent" || outcome === "transport_unknown" || !(KNOWN_ATTEMPT_OUTCOMES as readonly string[]).includes(outcome)) {
      unknownOutcomeRows += 1;
    }
    const est = recordedCents(a.estimated_cents);
    if (est !== null && (outcome === "hit" || outcome === "no_record")) {
      estimatedRows += 1;
      estimatedCents += est;
      if (a.ledger_status !== "recorded") {
        estimatedNotRecordedRows += 1;
        estimatedNotRecordedCents += est;
      }
    }
  }

  return {
    note:
      "Potential supplier liability with no ledger row: not added to total_cents, " +
      "not priced from a tariff, not netted. Unknown outcomes have no amount; they are not zero.",
    serving_holds: {
      groups: [...servingGroups.values()]
        .map((g) => ({ ...g, hold_cents: round4(g.hold_cents) }))
        .sort((a, b) => b.hold_cents - a.hold_cents || a.state.localeCompare(b.state)),
      open_rows_not_linked_to_ledger: servingOpenRows,
      open_hold_cents_not_linked_to_ledger: round4(servingOpenHoldCents),
      released_rejected_rows: servingReleasedRows,
      truncated: input.servingTruncated,
      detail:
        "Holds are linked by ledger_id only for exact single-match ceiling settlements; a funding/trial " +
        "hold can be settled without a link, so an unlinked succeeded hold is a reconciliation item, not proof of a missing charge.",
    },
    app_video_holds: {
      unsettled_rows: videoUnsettledRows,
      unsettled_hold_cents: round4(videoUnsettledHoldCents),
      settled_rows: videoSettledRows,
      released_rejected_rows: videoReleasedRows,
      truncated: input.videoTruncated,
      detail: "An accepted request settles into cost_ledger at acceptance; an unsettled, unreleased hold is retained potential liability; it does not prove supplier dispatch or charge.",
    },
    provider_attempts: {
      by_outcome: byOutcome,
      unknown_outcome_rows: unknownOutcomeRows,
      unknown_outcome_cents: null,
      estimated_rows: estimatedRows,
      estimated_cents: round4(estimatedCents),
      estimated_rows_not_recorded_in_ledger: estimatedNotRecordedRows,
      estimated_cents_not_recorded_in_ledger: round4(estimatedNotRecordedCents),
      truncated: input.attemptsTruncated,
      detail:
        "provider_attempt_receipts (property lookups). intent = durable pre-dispatch intent with no confirmed terminal outcome; it does not prove supplier dispatch. " +
        "transport_unknown = reply lost. Estimates are configured catalog amounts, never invoices.",
    },
  };
}
