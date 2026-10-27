// Called only after verifyAppleJWS and the subscription chronology writer.
// Subscription entitlement, supplier funding, and customer credits remain
// separate ledgers. A free introductory period never mints monthly credits.
import type { AppleTransaction } from "./applejws.ts";
import type { FundingContext } from "./funded-serving.ts";
import { HttpError } from "./http.ts";

export type MonthlyCreditEvent = "paid" | "refunded" | "reversed";

/** Decide from Apple-signed facts; absent price is not proof of payment. */
export function monthlyCreditEvent(
  tx: AppleTransaction,
  notificationType: string | null = null,
): MonthlyCreditEvent | null {
  if (tx.type !== "Auto-Renewable Subscription") return null;
  if (tx.environment !== "Production" && tx.environment !== "Sandbox") return null;
  // The launch combined budget is denominated in USD. A foreign storefront
  // needs its own signed-price/commission schedule before credit activation.
  if (tx.currency !== "USD" || tx.storefront !== "USA") return null;
  if (!tx.purchaseDate || !tx.expiresDate || !tx.signedDate) return null;
  if (notificationType === "REFUND" || notificationType === "REVOKE") return "refunded";
  if (notificationType === "REFUND_REVERSED") {
    return tx.inAppOwnershipType === "PURCHASED" &&
        typeof tx.priceMilliunits === "number" && tx.priceMilliunits > 0 &&
        tx.offerDiscountType !== "FREE_TRIAL"
      ? "reversed" : null;
  }
  if (tx.revocationDate) return "refunded";
  if (tx.inAppOwnershipType !== "PURCHASED" ||
      typeof tx.priceMilliunits !== "number" || tx.priceMilliunits <= 0 ||
      tx.offerDiscountType === "FREE_TRIAL") return null;
  return "paid";
}

export async function applyVerifiedMonthlyCredits(
  rpc: FundingContext["rpc"],
  orgId: string,
  tx: AppleTransaction,
  notificationType: string | null = null,
  eventSignedAt: string | null = null,
): Promise<unknown> {
  const event = monthlyCreditEvent(tx, notificationType);
  if (!event) return { granted: false, reason: "not_paid_subscription_period" };
  const { data, error } = await rpc("credit_verified_monthly_apply", {
    p_org: orgId,
    p_product: tx.productId,
    p_environment: tx.environment,
    p_original: tx.originalTransactionId,
    p_transaction: tx.transactionId,
    p_start: tx.purchaseDate,
    p_end: tx.expiresDate,
    p_price_milliunits: tx.priceMilliunits ?? null,
    p_transaction_signed_at: tx.signedDate,
    p_event_signed_at: eventSignedAt ?? tx.signedDate,
    p_event: event,
  });
  if (error) {
    throw new HttpError(503,
      "Your subscription is recorded, but its monthly credits could not be synchronized. Restore the purchase to retry.",
      "upstream");
  }
  return data;
}
