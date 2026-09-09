// _shared/property/rentcast.ts — RentCast property records.
//
// GET https://api.rentcast.io/v1/properties?address=<full address>
//     X-Api-Key: <RENTCAST_API_KEY>
//
// WHY THIS ONE FIRST: it is the only vendor in this class an owner can sign up
// for and get a key from the same afternoon, with no MLS membership and no
// sales call — which matters, because the alternative was blocking a real
// feature on a licence that has not been applied for yet. ~150M US property
// records: structural attributes, tax and sale history, and listing status.
//
// PRICING IS MODELLED, NOT BILLED. 7c is the $74 / 1,000-call tier, and the
// ledger's number is only as honest as this constant — confirm it against the
// first real invoice before it sets a COGS floor anywhere.

import { num, PropertyFacts, PropertyProvider, str } from "./provider.ts";

const BASE = "https://api.rentcast.io/v1/properties";

function key(): string | null {
  const k = Deno.env.get("RENTCAST_API_KEY")?.trim();
  return k ? k : null;
}

export const rentcast: PropertyProvider = {
  id: "rentcast",
  unitCents: 7.0,
  configured: () => key() !== null,

  async lookup(address: string): Promise<PropertyFacts | null> {
    const k = key();
    if (!k) return null;

    const url = `${BASE}?address=${encodeURIComponent(address)}&limit=1`;
    // A property lookup sits in front of a person tapping a button, so it gets
    // a short leash: better to tell them it did not answer than to hold the
    // form open. There is no retry — a second call is a second charge.
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12_000);
    let res: Response;
    try {
      res = await fetch(url, { headers: { "X-Api-Key": k, Accept: "application/json" }, signal: ctrl.signal });
    } finally {
      clearTimeout(timer);
    }

    // 404 is a real answer — "no record for that address" — and must not read
    // as an outage. Anything else that is not ok is logged WITHOUT the key and
    // without the body, which can echo the address back.
    if (res.status === 404) return null;
    if (!res.ok) {
      console.error(`rentcast: HTTP ${res.status}`);
      return null;
    }

    const body = await res.json().catch(() => null);
    // The route answers with an array when it matches by address, and a bare
    // object in some shapes. Accept both rather than depend on one.
    const rec = Array.isArray(body) ? body[0] : body;
    if (!rec || typeof rec !== "object") return null;
    const r = rec as Record<string, unknown>;

    const salePrice = num(r.lastSalePrice);
    return {
      matchedAddress: str(r.formattedAddress) ?? str(r.addressLine1),
      beds: num(r.bedrooms),
      baths: num(r.bathrooms),
      sqft: num(r.squareFootage),
      lotSqft: num(r.lotSize),
      yearBuilt: num(r.yearBuilt),
      propertyType: str(r.propertyType, 40),
      // Cents, because every other money value in this codebase is cents and a
      // dollars/cents mix-up is a 100x error in a price field on a listing.
      lastSalePriceCents: salePrice != null ? Math.round(salePrice * 100) : null,
      lastSaleDate: str(r.lastSaleDate, 40),
    };
  },
};
