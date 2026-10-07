// Cost arithmetic for an OWNER-REVIEWED package. This module neither grants
// features nor provisions funds; an arithmetic fit is not an invoice, tariff,
// Apple-proceeds, operating-cost or approval certificate.
import { geminiImageGenerationQuote } from "./funded-serving.ts";
import { geminiImageGenerationConfig } from "./providers/gemini.ts";

export const SERVING_RESERVE_CATEGORIES = ["storage", "delivery", "compute", "email", "support", "retention", "uncertainty"] as const;
export type ServingReserves = Record<typeof SERVING_RESERVE_CATEGORIES[number], number>;
export const BOUNDED_PHOTO_PACKAGE_VERSION = "one-gemini-1k-4096-plus-one-kontext-20261007";

/** One full-input Gemini liability plus one eligible4c no-mask Kontext. The
 * primary quote reads the adapter's actual combined thought/output ceiling.
 * Full131072 input authority is retained despite the new still-image limits. */
export function photoAdmissionHoldCents(): number {
  const quote = geminiImageGenerationQuote(geminiImageGenerationConfig("gemini-3.1-flash-image"));
  if (!quote || Math.ceil(quote.cents * 10000) !== 311296) throw new Error("The actual photo request has no verified conservative quote");
  return (Math.ceil(quote.cents * 10000) + 40000) / 10000;
}
function integer(value: number, name: string, maximum = 100_000_000) {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) throw new Error(`${name} must be nonnegative whole cents or units`);
}
export function validateServingReserves(value: unknown): ServingReserves {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).sort().join("|") !== [...SERVING_RESERVE_CATEGORIES].sort().join("|")) throw new Error("All seven exact serving reserves are required");
  const reserves = value as ServingReserves;
  for (const key of SERVING_RESERVE_CATEGORIES) integer(reserves[key],key);
  return { ...reserves };
}
export interface PackageCostInput {
  photoAdmissions: number;
  // All other included AI paths/fallbacks must be priced separately. Own
  // on-device footage needs no AI-video provider hold, but still needs the
  // storage/delivery/compute/retention reserves above.
  otherAiHoldCents: number;
  reserves: ServingReserves;
}
export function packageCost(input: PackageCostInput) {
  integer(input.photoAdmissions,"photoAdmissions",10000);
  integer(input.otherAiHoldCents,"otherAiHoldCents");
  const reserves = validateServingReserves(input.reserves);
  const photoMicrocents = Math.round(photoAdmissionHoldCents() * 10000) * input.photoAdmissions;
  // Round the aggregate liability UP, never round each tariff down.
  const photoCents = Math.ceil(photoMicrocents / 10000);
  const reserveCents = SERVING_RESERVE_CATEGORIES.reduce((n,key)=>n+reserves[key],0);
  return { policy: BOUNDED_PHOTO_PACKAGE_VERSION, photoCents, otherAiCents: input.otherAiHoldCents, reserveCents,
    totalCents: photoCents + input.otherAiHoldCents + reserveCents };
}
/** Existing retail funding allocates floor(net/4) across1or12 immutable slices.
 * Every advertised monthly allowance must fit the SMALLEST annual slice. */
export function retailPackageScenario(netCollectedCents: number, months: 1 | 12, input: PackageCostInput) {
  integer(netCollectedCents,"netCollectedCents");
  if (months !== 1 && months !== 12) throw new Error("Use one or twelve anchored service intervals");
  const inclusiveCents = Math.floor(netCollectedCents / 4), intervalCents = Math.floor(inclusiveCents / months), cost=packageCost(input);
  return { ...cost, minimumIntervalCents: intervalCents, remainderCents: intervalCents - cost.totalCents,
    arithmeticallyFits: cost.totalCents <= intervalCents, financiallyCertified: false as const, activated: false as const };
}
/** Sponsor cash is an explicit proposal until separately approved. No relation
 * to a supplier credit balance, subscription price or number of signups. */
export function trialPackageScenario(sponsorCents: number, input: PackageCostInput) {
  integer(sponsorCents,"sponsorCents");
  if (input.photoAdmissions !== 5) throw new Error("The approved trial scope includes five admitted photo requests");
  const cost = packageCost(input);
  return { ...cost, inclusiveCents: sponsorCents, remainderCents: sponsorCents - cost.totalCents,
    arithmeticallyFits: cost.totalCents <= sponsorCents, financiallyCertified: false as const, activated: false as const };
}
