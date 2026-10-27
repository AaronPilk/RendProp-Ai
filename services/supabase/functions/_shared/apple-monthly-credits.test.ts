import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { AppleTransaction } from "./applejws.ts";
import { applyVerifiedMonthlyCredits, monthlyCreditEvent } from "./apple-monthly-credits.ts";
import { HttpError } from "./http.ts";

const org = "af200001-0000-4000-8000-000000000001";
const paid: AppleTransaction = {
  transactionId: "monthly-1", originalTransactionId: "chain-1",
  productId: "com.rendprop.app.pro.monthly", bundleId: "com.rendprop.app",
  environment: "Production", purchaseDate: "2026-10-01T00:00:00Z",
  expiresDate: "2026-11-01T00:00:00Z", signedDate: "2026-10-01T00:01:00Z",
  revocationDate: null, revocationReason: null, type: "Auto-Renewable Subscription",
  inAppOwnershipType: "PURCHASED", appAccountToken: null, webOrderLineItemId: null,
  subscriptionGroupIdentifier: null, priceMilliunits: 99990, currency: "USD",
  storefront: "USA",
};

Deno.test("only a signed positive-price subscription period may mint monthly credits", () => {
  assertEquals(monthlyCreditEvent(paid), "paid");
  assertEquals(monthlyCreditEvent({ ...paid, priceMilliunits: 0 }), null);
  assertEquals(monthlyCreditEvent({ ...paid, priceMilliunits: null }), null);
  assertEquals(monthlyCreditEvent({ ...paid, offerDiscountType: "FREE_TRIAL" }), null);
  assertEquals(monthlyCreditEvent({ ...paid, inAppOwnershipType: "FAMILY_SHARED" }), null);
  assertEquals(monthlyCreditEvent({ ...paid, type: "Consumable" }), null);
  assertEquals(monthlyCreditEvent({ ...paid, expiresDate: null }), null);
  assertEquals(monthlyCreditEvent({ ...paid, currency: "EUR" }), null);
  assertEquals(monthlyCreditEvent({ ...paid, storefront: "CAN" }), null);
});

Deno.test("refund is terminal until Apple's explicit reversal", () => {
  assertEquals(monthlyCreditEvent({ ...paid, revocationDate: "2026-10-02T00:00:00Z" }), "refunded");
  assertEquals(monthlyCreditEvent(paid, "REFUND"), "refunded");
  assertEquals(monthlyCreditEvent(paid, "REFUND_REVERSED"), "reversed");
});

Deno.test("device and notification paths call the same environment-bound RPC", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const rpc = (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    return Promise.resolve({ data: { granted: true, credits: 250 }, error: null });
  };
  await applyVerifiedMonthlyCredits(rpc, org, paid);
  await applyVerifiedMonthlyCredits(rpc, org, { ...paid, environment: "Sandbox" },
    "DID_RENEW", "2026-10-01T00:02:00Z");
  assertEquals(calls.length, 2);
  assertEquals(calls[0].name, "credit_verified_monthly_apply");
  assertEquals(calls[0].args.p_org, org);
  assertEquals(calls[0].args.p_environment, "Production");
  assertEquals(calls[0].args.p_event, "paid");
  assertEquals(calls[1].args.p_environment, "Sandbox");
  assertEquals(calls[1].args.p_event_signed_at, "2026-10-01T00:02:00Z");
});

Deno.test("free trial dispatches no grant RPC and database outage is recoverable", async () => {
  let calls = 0;
  const trial = { ...paid, priceMilliunits: 0, offerType: 1,
    offerDiscountType: "FREE_TRIAL" };
  assertEquals(await applyVerifiedMonthlyCredits(() => {
    calls++;
    throw Error("must not dispatch");
  }, org, trial), { granted: false, reason: "not_paid_subscription_period" });
  assertEquals(calls, 0);
  const error = await assertRejects(() => applyVerifiedMonthlyCredits(
    () => Promise.resolve({ data: null, error: { message: "synthetic outage" } }),
    org, paid), HttpError);
  assertEquals(error.status, 503);
});

Deno.test("active paid catalog refuses acknowledgement when exact funding or Team capacity is unavailable", async () => {
  for (const reason of ["paid_funding_unavailable", "variant_not_funded"]) {
    const error = await assertRejects(() => applyVerifiedMonthlyCredits(
      () => Promise.resolve({ data: { granted: false, reason }, error: null }),
      org, paid), HttpError);
    assertEquals(error.status, 503);
  }
  // A dormant catalog and test-only Sandbox transaction do not promise a
  // Production monthly grant. Their ordinary no-grant outcome stays valid.
  assertEquals(await applyVerifiedMonthlyCredits(
    () => Promise.resolve({ data: { granted: false, reason: "not_configured" }, error: null }),
    org, paid), { granted: false, reason: "not_configured" });
  assertEquals(await applyVerifiedMonthlyCredits(
    () => Promise.resolve({ data: { granted: false, reason: "paid_funding_unavailable" }, error: null }),
    org, { ...paid, environment: "Sandbox" }),
    { granted: false, reason: "paid_funding_unavailable" });
});
