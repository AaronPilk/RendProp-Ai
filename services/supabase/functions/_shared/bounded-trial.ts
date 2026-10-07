import { assert, HttpError } from "./http.ts";

export type TrialBucket = { used: number; cap: number; remaining: number };
export type TrialUsage = {
  org_id: string; status: "active" | "exhausted" | "expired";
  starts_at: string; ends_at: string;
  walkthroughs: TrialBucket; photo_edits: TrialBucket; published_listings: TrialBucket;
  upload_budget_bytes: number; upload_used_bytes: number;
};
export type ServingActivation = { org_id: string; available: boolean; funded: boolean; authority: string };
export async function subscriptionServingActivation(admin: any, actor: string, org: string): Promise<ServingActivation> {
  const { data, error } = await admin.rpc("subscription_serving_activation", { p_actor: actor, p_org: org });
  assert(!error && data && data.org_id === org && typeof data.available === "boolean" && typeof data.funded === "boolean" &&
    ["private_sponsorship","app_review","brokerage","existing_non_apple","verified_retail","funded_trial","subscription_activation_unavailable"].includes(data.authority),
    503, "Subscription service activation could not be verified. Please retry.");
  assert(data.available === (data.authority !== "subscription_activation_unavailable") &&
    data.funded === ["app_review","verified_retail","funded_trial"].includes(data.authority), 503, "Subscription service activation could not be verified. Please retry.");
  return { org_id: org, available: data.available, funded: data.funded, authority: data.authority };
}
export function trialServingActivationForSync(funding: unknown, tx: { environment: string; offerType?: number | null; offerDiscountType?: string | null }, status: string): { funded: boolean; reason?: string } {
  const row = funding as { funded?: unknown; available?: unknown; reason?: unknown } | null;
  assert(row && typeof row.funded === "boolean", 503, "Subscription serving activation could not be verified. Please restore to retry.");
  if (tx.environment === "Production" && tx.offerType === 1 && tx.offerDiscountType === "FREE_TRIAL" && status === "active" && !row.funded && row.available !== true) {
    throw new HttpError(503, "Apple recorded your trial, but its included service is not activated. Your saved work remains available. Restore the subscription to retry.", "upstream");
  }
  return { funded: row.funded, ...(typeof row.reason === "string" ? { reason: row.reason } : {}) };
}
const unavailable = "Trial usage could not be verified. Please retry.";
function bucket(value: unknown, maximum: number): TrialBucket {
  const row = value as TrialBucket | null;
  assert(row && [row.used, row.cap, row.remaining].every(Number.isSafeInteger) &&
    row.cap > 0 && row.cap <= maximum && row.used >= 0 && row.used <= row.cap &&
    row.remaining === row.cap - row.used, 503, unavailable);
  return { used: row.used, cap: row.cap, remaining: row.remaining };
}
/** Trial eligibility is not an availability read. This release deliberately
 * has no enabled offer until pre-purchase money reservation and trusted video
 * duration enforcement exist. Current paid authority returns no old trial. */
export async function boundedTrialContext(admin: any, actor: string, org: string): Promise<{ trial_usage: TrialUsage | null; trial_offer: null }> {
  const { data, error } = await admin.rpc("subscription_trial_context", { p_actor: actor, p_org: org });
  assert(!error && data && typeof data === "object" && data.trial_offer === null &&
    Object.hasOwn(data, "trial_usage"), 503, unavailable);
  if (data.trial_usage === null) return { trial_usage: null, trial_offer: null };
  const row = data.trial_usage as TrialUsage;
  const start = Date.parse(row.starts_at), end = Date.parse(row.ends_at);
  assert(row.org_id === org && ["active", "exhausted", "expired"].includes(row.status) &&
    Number.isFinite(start) && Number.isFinite(end) && end > start && end - start <= 7 * 86400000 &&
    Number.isSafeInteger(row.upload_budget_bytes) && row.upload_budget_bytes > 0 && row.upload_budget_bytes <= 1073741824 &&
    Number.isSafeInteger(row.upload_used_bytes) && row.upload_used_bytes >= 0 && row.upload_used_bytes <= row.upload_budget_bytes,
    503, unavailable);
  const walkthroughs = bucket(row.walkthroughs, 1), photo_edits = bucket(row.photo_edits, 5), published_listings = bucket(row.published_listings, 1);
  assert(row.status === "expired" || end > Date.now(), 503, unavailable);
  assert(row.status !== "active" ||
    walkthroughs.remaining + photo_edits.remaining + published_listings.remaining > 0, 503, unavailable);
  return { trial_offer: null, trial_usage: { org_id: org, status: row.status, starts_at: row.starts_at, ends_at: row.ends_at,
    walkthroughs, photo_edits, published_listings, upload_budget_bytes: row.upload_budget_bytes, upload_used_bytes: row.upload_used_bytes } };
}
