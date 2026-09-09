// _shared/property/provider.ts — where a property's facts come from.
//
// THE POINT OF THE INTERFACE, on day one: the owner's plan is an MLS/IDX feed
// once his licence lands ("we will wire MLS API when we have our license"). A
// licensed vendor covers him nationwide TODAY without one. Both answer the same
// question — "what do the records say about this address" — so they are one
// interface with two implementations, and the day the MLS feed arrives it is a
// new file plus one line in `PROVIDERS`, not a rebuild of the screen.
//
// WHAT IS DELIBERATELY NOT HERE: photos. No vendor licenses a listing's
// photographs, because they belong to the photographer or the MLS rather than
// to the portal or the agent — that is the whole VHT v. Zillow story, and it is
// equally true at RentCast, at ATTOM and at Zillow. An agent's own listing
// photos come from the agent. `PropertyFacts` has no photo field so that no
// future caller can quietly start expecting one.

export interface PropertyFacts {
  /** Echoed back so the client can show what was actually matched — a lookup
   *  that resolved a DIFFERENT house must be visible, not silent. */
  matchedAddress?: string | null;
  beds?: number | null;
  /** Half-baths are real: 2.5 is a value, not a rounding error. */
  baths?: number | null;
  sqft?: number | null;
  lotSqft?: number | null;
  yearBuilt?: number | null;
  propertyType?: string | null;
  lastSalePriceCents?: number | null;
  lastSaleDate?: string | null;
}

export interface PropertyProvider {
  readonly id: string;
  /** False when the deploy has no credential for it. A provider that cannot run
   *  is SKIPPED, never attempted — an unconfigured key must not read as a
   *  failed lookup to the agent. */
  configured(): boolean;
  /** Cents billed per successful call, for the ledger. Modelled, like every
   *  other unit price in this codebase — confirm against the first invoice. */
  readonly unitCents: number;
  lookup(address: string): Promise<PropertyFacts | null>;
}

/** Number, or null. Providers send "", "N/A", and strings-that-are-numbers. */
export function num(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string") {
    const n = Number(v.replace(/[$,]/g, "").trim());
    return Number.isFinite(n) && v.trim() !== "" ? n : null;
  }
  return null;
}

/** Bounded, trimmed string or null. */
export function str(v: unknown, max = 200): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

/**
 * The cache key. Lowercase, strip everything that is not a letter, digit or
 * space, collapse whitespace.
 *
 * Lossy ON PURPOSE: "1401 45th Ave N, Saint Petersburg, FL 33703" and
 * "1401 45th ave n  saint petersburg fl 33703" are the same house and must not
 * be two purchases. The address the caller typed is stored alongside, so
 * nothing is lost that a human would need.
 */
export function addressKey(address: string): string {
  return address
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 300);
}

/** True when the fact set is worth caching and returning — a provider that
 *  matched an address but knows nothing about it is not an answer. */
export function hasSubstance(f: PropertyFacts): boolean {
  return f.beds != null || f.baths != null || f.sqft != null ||
         f.yearBuilt != null || f.lastSalePriceCents != null;
}
