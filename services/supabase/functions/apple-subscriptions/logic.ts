// apple-subscriptions/logic.ts — the decisions POST /notify makes, as pure
// functions.
//
// `index.ts` is the only caller. It is split out for exactly one reason: this
// is the part that must be TESTED, and a module that calls `Deno.serve` at
// import time cannot be imported by a test. (Same split as events/schema.ts and
// _shared/router.ts.) Behaviour is byte-identical to what lived in index.ts —
// this file moved code, it did not change it.
//
// No network, no env, no database, no `Deno.serve`. Everything here takes an
// ALREADY-VERIFIED payload: nothing in this file decides whether Apple signed
// something, only what a signed thing means.

import type {
  AppleRenewalInfo,
  AppleTransaction,
  SubscriptionStatus,
} from "../_shared/applejws.ts";
import { deriveEntitlement, productToPlan } from "../_shared/applejws.ts";

/** Everything the handler branches on, pulled out of a verified notification. */
export interface NotificationFacts {
  uuid: string;
  type: string;
  subtype: string | null;
  environment: string;
  bundleId: string;
  transaction: AppleTransaction | null;
  renewal: AppleRenewalInfo | null;
}

/**
 * What each notification type means for the entitlement.
 *
 *   "derive"  — believe the signed transaction: active if it has not expired,
 *               grace if Apple is retrying inside a grace window, expired otherwise.
 *   "expired" / "refunded" / "revoked" — the type itself is the verdict, whatever
 *               the transaction's dates say.
 *   "grace"   — DID_FAIL_TO_RENEW with subtype GRACE_PERIOD only.
 *   "ignore"  — record it, change nothing. Either it is not about an entitlement
 *               (TEST, CONSUMPTION_REQUEST) or it is a request rather than an
 *               outcome (RENEWAL_EXTENSION — RENEWAL_EXTENDED is the outcome).
 *
 * Anything absent from this table is treated as "ignore" AND logged by name, so
 * a new Apple notification type shows up in the logs instead of as a 500.
 */
export type Verdict = "derive" | "grace" | "expired" | "refunded" | "revoked" | "ignore";

export const VERDICTS: Readonly<Record<string, Verdict>> = Object.freeze({
  SUBSCRIBED: "derive",
  DID_RENEW: "derive",
  DID_CHANGE_RENEWAL_PREF: "derive",
  DID_CHANGE_RENEWAL_STATUS: "derive",
  PRICE_INCREASE: "derive",
  OFFER_REDEEMED: "derive",
  RENEWAL_EXTENDED: "derive",
  REFUND_DECLINED: "derive",
  REFUND_REVERSED: "derive",
  METADATA_UPDATE: "derive",
  DID_FAIL_TO_RENEW: "derive", // upgraded to "grace" when subtype = GRACE_PERIOD
  EXPIRED: "expired",
  GRACE_PERIOD_EXPIRED: "expired",
  REFUND: "refunded",
  REVOKE: "revoked",
  TEST: "ignore",
  CONSUMPTION_REQUEST: "ignore",
  RENEWAL_EXTENSION: "ignore",
  EXTERNAL_PURCHASE_TOKEN: "ignore",
  ONE_TIME_CHARGE: "ignore",
  MIGRATION: "ignore",
});

/**
 * `null` when Apple sent a type this build has never heard of — the caller logs
 * the name and treats it as "ignore", which is what keeps a new Apple feature
 * from becoming a 500 and a day of retries.
 *
 * Own-property lookup, not `VERDICTS[type]`: a notificationType of
 * "constructor" or "toString" would otherwise resolve to something off
 * Object.prototype and be neither a Verdict nor undefined.
 */
export function lookupVerdict(type: string): Verdict | null {
  return Object.prototype.hasOwnProperty.call(VERDICTS, type)
    ? VERDICTS[type]
    : null;
}

/** The verdict for a notification, with the one subtype that changes it. */
export function resolveVerdict(facts: NotificationFacts): Verdict {
  const known = lookupVerdict(facts.type);
  if (known === null) return "ignore";
  if (facts.type === "DID_FAIL_TO_RENEW" && facts.subtype === "GRACE_PERIOD") {
    // Billing grace is on: the customer keeps the plan until
    // gracePeriodExpiresDate, which deriveEntitlement() already prefers.
    return "grace";
  }
  return known;
}

/**
 * The arguments apply_apple_entitlement() needs, minus the org.
 *
 * This is computed ONCE, at receipt, and stored on the notification row — so a
 * notification that arrives before the app has linked a workspace is replayed
 * later by POST /me/entitlement with byte-identical arguments instead of being
 * re-derived by a second copy of these rules living in another function.
 */
export interface PendingEntitlement {
  original_transaction_id: string;
  transaction_id: string;
  product_id: string;
  plan: string | null;
  environment: string;
  status: SubscriptionStatus;
  expires_at: string | null;
  auto_renew: boolean | null;
  notification_type: string;
}

export function computeEntitlement(
  facts: NotificationFacts,
  verdict: Verdict,
  now?: Date,
): PendingEntitlement {
  const tx = facts.transaction!;
  const derived = deriveEntitlement(tx, facts.renewal, {
    revoked: verdict === "revoked",
    ...(now ? { now } : {}),
  });

  let status: SubscriptionStatus = derived.status;
  let expiresAt = derived.expiresAt;
  if (verdict === "expired") {
    status = "expired";
  } else if (verdict === "refunded" || verdict === "revoked") {
    status = verdict;
    expiresAt = tx.revocationDate ?? derived.expiresAt;
  } else if (verdict === "grace") {
    // Apple sends DID_FAIL_TO_RENEW BEFORE the paid period ends too, so only
    // move to grace once the period has actually run out.
    status = derived.status === "active" ? "active" : "grace";
    expiresAt = derived.status === "active"
      ? derived.expiresAt
      : (facts.renewal?.gracePeriodExpiresDate ?? derived.expiresAt);
  }

  return {
    original_transaction_id: tx.originalTransactionId,
    transaction_id: tx.transactionId,
    product_id: tx.productId,
    plan: productToPlan(tx.productId),
    environment: facts.environment,
    status,
    expires_at: expiresAt,
    auto_renew: derived.autoRenew,
    notification_type: facts.subtype ? `${facts.type}/${facts.subtype}` : facts.type,
  };
}

/**
 * The outer payload minus the signed blobs (they are stored decoded instead —
 * migration 0019 §2 explains why) and minus anything that is not needed to
 * replay the notification later.
 */
export function summariseNotification(
  outer: Record<string, unknown>,
  facts: NotificationFacts,
): Record<string, unknown> {
  const data = (outer.data ?? {}) as Record<string, unknown>;
  return {
    notificationType: facts.type,
    subtype: facts.subtype,
    notificationUUID: facts.uuid,
    version: typeof outer.version === "string" ? outer.version : null,
    signedDate: typeof outer.signedDate === "number" ? outer.signedDate : null,
    bundleId: facts.bundleId,
    environment: facts.environment,
    appAppleId: typeof data.appAppleId === "number" ? data.appAppleId : null,
    status: typeof data.status === "number" ? data.status : null,
  };
}
