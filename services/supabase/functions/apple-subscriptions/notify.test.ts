// notify.test.ts — the decisions POST /apple-subscriptions/notify makes.
//
//   deno test --allow-env --allow-net --allow-read apple-subscriptions/notify.test.ts
//
// index.ts calls Deno.serve at import time and cannot be imported by a test, so
// the branching lives in ./logic.ts (same split as events/schema.ts). These
// tests are the S1 adversarial review's answer to "what does each Apple
// notification type actually DO to a paying customer's plan" — every row of the
// verdict table, exercised, plus the two that would cost money if they were
// wrong: a REFUND_REVERSED that must re-grant, and a DID_CHANGE_RENEWAL_PREF
// that must NOT downgrade anybody today.
//
// Nothing here verifies a signature: by the time these functions run, the JWS
// has already been through verifyAppleJWS() and the payload is Apple's word.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { AppleRenewalInfo, AppleTransaction } from "../_shared/applejws.ts";
import {
  computeEntitlement,
  lookupVerdict,
  type NotificationFacts,
  resolveVerdict,
  summariseNotification,
  VERDICTS,
  type Verdict,
} from "./logic.ts";

const NOW = new Date("2026-09-05T12:00:00.000Z");
const FUTURE = "2026-10-05T12:00:00.000Z";
const PAST = "2026-08-05T12:00:00.000Z";
const GRACE_END = "2026-09-20T12:00:00.000Z";

function tx(over: Partial<AppleTransaction> = {}): AppleTransaction {
  return {
    transactionId: "2000000700000001",
    originalTransactionId: "2000000700000000",
    productId: "com.rendprop.app.pro.monthly",
    bundleId: "com.rendprop.app",
    environment: "Production",
    purchaseDate: PAST,
    expiresDate: FUTURE,
    revocationDate: null,
    revocationReason: null,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    appAccountToken: null,
    webOrderLineItemId: "1",
    subscriptionGroupIdentifier: "rendprop_plans",
    signedDate: PAST,
    ...over,
  };
}

function renewal(over: Partial<AppleRenewalInfo> = {}): AppleRenewalInfo {
  return {
    originalTransactionId: "2000000700000000",
    productId: "com.rendprop.app.pro.monthly",
    autoRenewProductId: "com.rendprop.app.pro.monthly",
    autoRenewStatus: 1,
    renewalDate: FUTURE,
    gracePeriodExpiresDate: null,
    expirationIntent: null,
    isInBillingRetryPeriod: null,
    priceIncreaseStatus: null,
    offerIdentifier: null,
    offerType: null,
    environment: "Production",
    signedDate: PAST,
    ...over,
  };
}

function facts(over: Partial<NotificationFacts> = {}): NotificationFacts {
  return {
    uuid: "b7d4a2f0-0000-4000-8000-000000000001",
    type: "DID_RENEW",
    subtype: null,
    environment: "Production",
    bundleId: "com.rendprop.app",
    transaction: tx(),
    renewal: renewal(),
    ...over,
  };
}

// ── The verdict table ────────────────────────────────────────────────────────

Deno.test("every notification type Apple documents has a deliberate verdict", () => {
  // If Apple ships a new type it must land on "ignore" and be logged, never a
  // 500 — Apple retries a 5xx for about a day and then stops.
  for (const t of ["SOMETHING_NEW", "", "RENEWAL_EXTENDED_V2"]) {
    assertEquals(resolveVerdict(facts({ type: t })), "ignore");
  }
  // …and a type named after something on Object.prototype is not a verdict.
  for (const t of ["constructor", "toString", "__proto__", "valueOf"]) {
    assertEquals(lookupVerdict(t), null);
    assertEquals(resolveVerdict(facts({ type: t })), "ignore");
  }
});

Deno.test("the types that must never change a plan are 'ignore'", () => {
  for (
    const t of [
      "TEST", // App Store Connect's "Send Test Notification"
      "CONSUMPTION_REQUEST", // a refund investigation; no entitlement change
      "RENEWAL_EXTENSION", // the REQUEST; RENEWAL_EXTENDED is the outcome
      "EXTERNAL_PURCHASE_TOKEN", // external purchase link, not our subscription
      "ONE_TIME_CHARGE",
      "MIGRATION",
    ]
  ) {
    assertEquals(resolveVerdict(facts({ type: t })), "ignore", t);
  }
});

Deno.test("the terminal types are terminal", () => {
  assertEquals(resolveVerdict(facts({ type: "EXPIRED" })), "expired");
  assertEquals(resolveVerdict(facts({ type: "GRACE_PERIOD_EXPIRED" })), "expired");
  assertEquals(resolveVerdict(facts({ type: "REFUND" })), "refunded");
  assertEquals(resolveVerdict(facts({ type: "REVOKE" })), "revoked");
});

Deno.test("DID_FAIL_TO_RENEW becomes grace ONLY on the GRACE_PERIOD subtype", () => {
  assertEquals(resolveVerdict(facts({ type: "DID_FAIL_TO_RENEW" })), "derive");
  assertEquals(
    resolveVerdict(facts({ type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD" })),
    "grace",
  );
});

// ── What each verdict does to the entitlement ────────────────────────────────

Deno.test("DID_CHANGE_RENEWAL_PREF does NOT downgrade today", () => {
  // A customer who schedules a downgrade keeps what they paid for until the
  // period ends. The notification carries the CURRENT transaction and a renewal
  // info naming the NEXT product — believing autoRenewProductId here would take
  // a plan away from somebody who is still paid up.
  const e = computeEntitlement(
    facts({
      type: "DID_CHANGE_RENEWAL_PREF",
      subtype: "DOWNGRADE",
      renewal: renewal({ autoRenewProductId: "com.rendprop.app.starter.monthly" }),
    }),
    "derive",
    NOW,
  );
  assertEquals(e.plan, "pro");
  assertEquals(e.product_id, "com.rendprop.app.pro.monthly");
  assertEquals(e.status, "active");
  assertEquals(e.expires_at, FUTURE);
  assertEquals(e.notification_type, "DID_CHANGE_RENEWAL_PREF/DOWNGRADE");
});

Deno.test("DID_CHANGE_RENEWAL_STATUS (auto-renew off) keeps the plan and records the intent", () => {
  const e = computeEntitlement(
    facts({
      type: "DID_CHANGE_RENEWAL_STATUS",
      subtype: "AUTO_RENEW_DISABLED",
      renewal: renewal({ autoRenewStatus: 0 }),
    }),
    "derive",
    NOW,
  );
  assertEquals(e.status, "active");
  assertEquals(e.auto_renew, false);
  assertEquals(e.plan, "pro");
});

Deno.test("REFUND_REVERSED re-grants: Apple took the refund back", () => {
  // The money came back to us, so the customer's plan comes back too. The
  // transaction Apple sends with a reversal no longer carries a revocationDate.
  const e = computeEntitlement(facts({ type: "REFUND_REVERSED" }), "derive", NOW);
  assertEquals(e.status, "active");
  assertEquals(e.plan, "pro");
});

Deno.test("REFUND_DECLINED changes nothing — the customer never lost the plan", () => {
  const e = computeEntitlement(facts({ type: "REFUND_DECLINED" }), "derive", NOW);
  assertEquals(e.status, "active");
});

Deno.test("REFUND and REVOKE end the entitlement at the revocation instant", () => {
  const revoked = tx({ revocationDate: PAST, revocationReason: 1 });
  const refund = computeEntitlement(
    facts({ type: "REFUND", transaction: revoked }),
    "refunded",
    NOW,
  );
  assertEquals(refund.status, "refunded");
  assertEquals(refund.expires_at, PAST);

  const revoke = computeEntitlement(
    facts({ type: "REVOKE", transaction: revoked }),
    "revoked",
    NOW,
  );
  assertEquals(revoke.status, "revoked");
  assertEquals(revoke.expires_at, PAST);
});

Deno.test("GRACE_PERIOD_EXPIRED expires even while the grace window is still open", () => {
  // Apple has given up retrying. A gracePeriodExpiresDate still in the future
  // must not keep the plan alive past the notification that ended it.
  const e = computeEntitlement(
    facts({
      type: "GRACE_PERIOD_EXPIRED",
      transaction: tx({ expiresDate: PAST }),
      renewal: renewal({ gracePeriodExpiresDate: GRACE_END, isInBillingRetryPeriod: true }),
    }),
    "expired",
    NOW,
  );
  assertEquals(e.status, "expired");
});

Deno.test("DID_FAIL_TO_RENEW/GRACE_PERIOD keeps the plan until the grace window closes", () => {
  const inGrace = computeEntitlement(
    facts({
      type: "DID_FAIL_TO_RENEW",
      subtype: "GRACE_PERIOD",
      transaction: tx({ expiresDate: PAST }),
      renewal: renewal({ gracePeriodExpiresDate: GRACE_END, isInBillingRetryPeriod: true }),
    }),
    "grace",
    NOW,
  );
  assertEquals(inGrace.status, "grace");
  assertEquals(inGrace.expires_at, GRACE_END);

  // Apple also sends DID_FAIL_TO_RENEW BEFORE the paid period ends. That must
  // stay `active` — the customer has not lost anything yet.
  const stillPaid = computeEntitlement(
    facts({
      type: "DID_FAIL_TO_RENEW",
      subtype: "GRACE_PERIOD",
      renewal: renewal({ gracePeriodExpiresDate: GRACE_END }),
    }),
    "grace",
    NOW,
  );
  assertEquals(stillPaid.status, "active");
  assertEquals(stillPaid.expires_at, FUTURE);
});

Deno.test("RENEWAL_EXTENDED and OFFER_REDEEMED follow the transaction they carry", () => {
  const extended = computeEntitlement(
    facts({
      type: "RENEWAL_EXTENDED",
      transaction: tx({ expiresDate: "2026-12-25T12:00:00.000Z" }),
    }),
    "derive",
    NOW,
  );
  assertEquals(extended.status, "active");
  assertEquals(extended.expires_at, "2026-12-25T12:00:00.000Z");

  const offer = computeEntitlement(
    facts({
      type: "OFFER_REDEEMED",
      transaction: tx({ productId: "com.rendprop.app.team.annual" }),
      renewal: renewal({ offerIdentifier: "winback", offerType: 3 }),
    }),
    "derive",
    NOW,
  );
  assertEquals(offer.plan, "team");
});

Deno.test("PRICE_INCREASE never moves a plan by itself", () => {
  const e = computeEntitlement(
    facts({ type: "PRICE_INCREASE", renewal: renewal({ priceIncreaseStatus: 0 }) }),
    "derive",
    NOW,
  );
  assertEquals(e.status, "active");
  assertEquals(e.plan, "pro");
});

Deno.test("a product this build does not sell maps to no plan at all", () => {
  // index.ts refuses to apply these — the point here is that nothing invents a
  // plan for an unmapped product on the way through.
  const e = computeEntitlement(
    facts({ transaction: tx({ productId: "com.rendprop.app.enterprise.monthly" }) }),
    "derive",
    NOW,
  );
  assertEquals(e.plan, null);
});

// ── The stored summary ───────────────────────────────────────────────────────

Deno.test("the stored notification summary carries no signed blob and no token", () => {
  const f = facts({ transaction: tx({ appAccountToken: "0d1c8f8e-9a6b-4f1e-9d2c-7b3a5e6f0011" }) });
  const summary = summariseNotification({
    notificationType: "DID_RENEW",
    notificationUUID: f.uuid,
    version: "2.0",
    signedDate: 1_757_073_600_000,
    data: {
      bundleId: "com.rendprop.app",
      environment: "Production",
      appAppleId: 6_500_000_000,
      status: 1,
      signedTransactionInfo: "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJTRUNSRVQiXX0.payload.sig",
      signedRenewalInfo: "eyJhbGciOiJFUzI1NiJ9.payload.sig",
    },
  }, f);

  const serialized = JSON.stringify(summary);
  assert(!serialized.includes("signedTransactionInfo"), "no signed transaction blob");
  assert(!serialized.includes("signedRenewalInfo"), "no signed renewal blob");
  assert(!serialized.includes("eyJ"), "no JWS of any kind");
  assertEquals(summary.notificationUUID, f.uuid);
  assertEquals(summary.environment, "Production");
});

Deno.test("the verdict table is frozen and holds only known verdicts", () => {
  const allowed: Verdict[] = ["derive", "grace", "expired", "refunded", "revoked", "ignore"];
  assert(Object.isFrozen(VERDICTS));
  for (const [type, verdict] of Object.entries(VERDICTS)) {
    assert(allowed.includes(verdict), `${type} -> ${verdict}`);
  }
});
