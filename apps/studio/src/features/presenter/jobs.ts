import { mediaURL, uuid } from "../../data/contracts";
import { invalid, list, permissions, rev, row, scope, str } from "./model";

export const JOB_STATES = { reserved: "Preparing generation", dispatching: "Sending to the provider", uncertain: "Submission needs reconciliation", queued: "Queued", processing: "Generating", review: "Ready for your private review", accepted: "Accepted", rejected: "Rejected", importing: "Adding to property media", imported: "Added to property media", cancel_requested: "Cancellation requested", cancelled: "Cancelled", failed: "Failed", invalidated: "Approval withdrawn" } as const;
export type JobStatus = keyof typeof JOB_STATES;
export type PresenterQuote = { id: string; draft_id: string; draft_revision: number; profile_revision: number; quote_cents: number; max_cost_cents: number; estimate_usd: string; expires_at: string; consumed: boolean };
export type PresenterJob = { id: string; quote_id: string; draft_id: string; draft_revision: number | null; profile_revision: number | null; revision: number; status: JobStatus;
  quote_cents: number; max_cost_cents: number; held_cents: number; estimate_usd: string; charged_cents: number | null; actual_usd: string | null; imported_asset_id: string | null;
  output: { sha256: string; bytes: number; duration_s: number; preview_url?: string; preview_expires_at?: string } | null;
  permissions: { can_cancel: boolean; can_review: boolean; can_import: boolean };
};
export type JobsState = { closed_submission?: { quote_id: string; idempotency_key: string }; jobs: PresenterJob[]; quotes: PresenterQuote[]; runtime: { available: boolean; reason: string } };
export type Submission = { quote_id: string; idempotency_key: string; max_cost_cents: number };
export const dollars = (amount: string) => `$${Number(amount).toFixed(2)} USD`;
export const activeJob = (j: PresenterJob) => ["reserved", "dispatching", "uncertain", "queued", "processing", "importing", "cancel_requested"].includes(j.status);
function cents(value: unknown): number { if (!Number.isSafeInteger(value) || Number(value) < 0 || Number(value) > 1000000) invalid(); return Number(value); }
function usd(value: unknown): string { if (typeof value !== "string" || !/^(0|[1-9]\d{0,5})(\.\d{1,8})?$/.test(value) || Number(value) > 10000) invalid(); return value; }
function date(value: unknown): string { const s = str(value, 80); if (!Number.isFinite(Date.parse(s))) invalid(); return s; }
function outputURL(raw: unknown, org: string, listing: string, job: string, expires: string): string {
  const original = str(raw, 8192), url = new URL(original), parts = url.pathname.split("/");
  if (parts.length !== 6 || parts[2] !== "presenter-private" || parts[3] !== org || parts[4] !== job || parts[5] !== "output.mp4") invalid();
  url.pathname = `/${parts[1]}/renders/${org}/${listing}/${job}/output.mp4`;
  mediaURL(url.href, org, listing, expires, Date.now());
  return original;
}
export function decodeJobs(raw: unknown, org: string, listing: string): JobsState {
  const data = row(raw); scope(data, org, listing);
  const runtime = row(data.runtime); if (typeof runtime.available !== "boolean") invalid();
  const jobs = list(data.jobs).map(value => { const j = row(value), id = uuid(j.id); if (!Object.hasOwn(JOB_STATES, String(j.status))) invalid();
    let output: PresenterJob["output"] = null;
    if (j.output) { const o = row(j.output); if (typeof o.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(o.sha256) || !Number.isSafeInteger(o.bytes) || Number(o.bytes) < 1 || typeof o.duration_s !== "number" || !Number.isFinite(o.duration_s) || o.duration_s < 0.1 || o.duration_s > 60) invalid();
      const expires = o.preview_url === undefined ? undefined : date(o.preview_expires_at);
      output = { sha256: o.sha256, bytes: Number(o.bytes), duration_s: o.duration_s, ...(expires ? { preview_expires_at: expires, preview_url: outputURL(o.preview_url, org, listing, id, expires) } : {}) };
    }
    return { id, quote_id: uuid(j.quote_id), draft_id: uuid(j.draft_id), draft_revision: j.status === "invalidated" && j.draft_revision === null ? null : rev(j.draft_revision), profile_revision: j.status === "invalidated" && j.profile_revision === null ? null : rev(j.profile_revision), revision: rev(j.revision), status: j.status as JobStatus,
      quote_cents: cents(j.quote_cents), max_cost_cents: cents(j.max_cost_cents), held_cents: cents(j.held_cents), estimate_usd: usd(j.estimate_usd), charged_cents: j.charged_cents === null ? null : cents(j.charged_cents), actual_usd: j.actual_usd === null ? null : usd(j.actual_usd), output,
      imported_asset_id: j.imported_asset_id === null ? null : uuid(j.imported_asset_id), permissions: permissions(j.permissions, ["can_cancel", "can_review", "can_import"]) };
  });
  const quotes = list(data.quotes).map(value => { const q = row(value); if (typeof q.consumed !== "boolean") invalid(); return { id: uuid(q.id), draft_id: uuid(q.draft_id), draft_revision: rev(q.draft_revision), profile_revision: rev(q.profile_revision), quote_cents: cents(q.quote_cents), max_cost_cents: cents(q.max_cost_cents), estimate_usd: usd(q.estimate_usd), expires_at: date(q.expires_at), consumed: q.consumed }; });
  if (new Set(jobs.map(j => j.id)).size !== jobs.length || new Set(quotes.map(q => q.id)).size !== quotes.length) invalid();
  const closed = data.closed_submission == null ? null : row(data.closed_submission);
  return { ...(closed ? { closed_submission: { quote_id: uuid(closed.quote_id), idempotency_key: uuid(closed.idempotency_key) } } : {}), jobs, quotes, runtime: { available: runtime.available, reason: str(runtime.reason, 500) } };
}
export function submissionKey(org: string, user: string, listing: string) { return `rendprop:presenter-submit:${org}:${user}:${listing}`; }
export function readSubmission(value: string | null): Submission | null { if (value === null) return null; const s = row(JSON.parse(value)); return { quote_id: uuid(s.quote_id), idempotency_key: uuid(s.idempotency_key), max_cost_cents: cents(s.max_cost_cents) }; }

export function resolvesSubmission(state: JobsState, marker: Submission): boolean { return state.jobs.some(j => j.quote_id === marker.quote_id) || (state.closed_submission?.quote_id === marker.quote_id && state.closed_submission.idempotency_key === marker.idempotency_key); }

export const AUTO_CHECK_LIMIT = 20;
export function nextAutoCheck(jobs: PresenterJob[], attempts: Record<string, number>, enabled: boolean): PresenterJob | undefined { return enabled ? jobs.find(j => ["reserved", "queued", "processing", "cancel_requested"].includes(j.status) && (attempts[j.id] ?? 0) < AUTO_CHECK_LIMIT) : undefined; }
