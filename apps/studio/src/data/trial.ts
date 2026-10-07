import { StudioError } from "./config";

export type TrialMeter = { used: number; cap: number; remaining: number };
export type TrialUsage = {
  orgId: string;
  status: "active" | "exhausted" | "expired";
  startsAt: string;
  endsAt: string;
  walkthroughs: TrialMeter;
  photoEdits: TrialMeter;
  publishedListings: TrialMeter;
  uploadBudgetBytes: number;
  uploadUsedBytes: number;
};
export type TrialOffer = {
  enabled: true;
  walkthroughs: number;
  photoEdits: number;
  publishedListings: number;
  maxDays: number;
  maxVideoSeconds: number;
  uploadBudgetBytes: number;
};
const servingAuthorities = {
  private_sponsorship: [true, false],
  app_review: [true, true],
  brokerage: [true, false],
  existing_non_apple: [true, false],
  verified_retail: [true, true],
  funded_trial: [true, true],
  subscription_activation_unavailable: [false, false],
} as const;
export type ServingActivation = {
  orgId: string;
  available: boolean;
  funded: boolean;
  authority: keyof typeof servingAuthorities;
};

/** Missing legacy data is compatible; a present activation receipt must be exact. */
export function decodeServingActivation(value: unknown, orgId: string): ServingActivation | null {
  if (value === undefined) return null;
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new StudioError("invalid-response", "Your service activation could not be verified. Refresh before starting new work.");
  }
  const row = value as Record<string, unknown>;
  if (row.org_id !== orgId) throw new StudioError("identity-mismatch", "This service activation belongs to a different workspace. Reload Studio.");
  if (typeof row.authority !== "string" || !Object.hasOwn(servingAuthorities, row.authority)) {
    throw new StudioError("invalid-response", "Your service activation could not be verified. Refresh before starting new work.");
  }
  const authority = row.authority as ServingActivation["authority"], [available, funded] = servingAuthorities[authority];
  if (row.available !== available || row.funded !== funded) {
    throw new StudioError("invalid-response", "Your service activation could not be verified. Refresh before starting new work.");
  }
  return { orgId, available, funded, authority };
}

function invalid(): never {
  throw new StudioError("invalid-response", "Your trial allowance could not be verified. Refresh your account before starting new work.");
}
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return invalid();
  return value as Record<string, unknown>;
}
function count(value: unknown, positive = false): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < (positive ? 1 : 0)) return invalid();
  return value;
}
function timestamp(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) return invalid();
  return value;
}
function meter(value: unknown, maxCap: number): TrialMeter {
  const row = record(value), used = count(row.used), cap = count(row.cap, true), remaining = count(row.remaining);
  if (cap > maxCap || used > cap || remaining !== cap - used) return invalid();
  return { used, cap, remaining };
}

/** The surrounding /me account and workspace are checked before this additive payload. */
export function decodeTrialUsage(value: unknown, orgId: string): TrialUsage | null {
  if (value == null) return null;
  const row = record(value);
  if (row.org_id !== orgId) throw new StudioError("identity-mismatch", "This trial belongs to a different workspace. Reload Studio.");
  if (row.status !== "active" && row.status !== "exhausted" && row.status !== "expired") return invalid();
  const startsAt = timestamp(row.starts_at), endsAt = timestamp(row.ends_at);
  const duration = Date.parse(endsAt) - Date.parse(startsAt);
  if (duration <= 0 || duration > 7 * 86_400_000) return invalid();
  const uploadBudgetBytes = count(row.upload_budget_bytes, true), uploadUsedBytes = count(row.upload_used_bytes);
  if (uploadBudgetBytes > 1_073_741_824 || uploadUsedBytes > uploadBudgetBytes) return invalid();
  return {
    orgId, status: row.status, startsAt, endsAt,
    walkthroughs: meter(row.walkthroughs, 1), photoEdits: meter(row.photo_edits, 5),
    publishedListings: meter(row.published_listings, 1), uploadBudgetBytes, uploadUsedBytes,
  };
}

/** Dormant configuration never becomes a numerical customer promise. */
export function decodeTrialOffer(value: unknown): TrialOffer | null {
  if (value == null) return null;
  const row = record(value);
  if (row.enabled === false) return null;
  if (row.enabled !== true) return invalid();
  const maxDays = count(row.max_days, true);
  const walkthroughs = count(row.walkthroughs, true), photoEdits = count(row.photo_edits, true), publishedListings = count(row.published_listings, true);
  const maxVideoSeconds = count(row.max_video_seconds, true), uploadBudgetBytes = count(row.upload_budget_bytes, true);
  if (maxDays > 7 || walkthroughs > 1 || photoEdits > 5 || publishedListings > 1 || maxVideoSeconds > 90 || uploadBudgetBytes > 1_073_741_824) return invalid();
  return {
    enabled: true, walkthroughs, photoEdits, publishedListings, maxDays,
    maxVideoSeconds, uploadBudgetBytes,
  };
}
