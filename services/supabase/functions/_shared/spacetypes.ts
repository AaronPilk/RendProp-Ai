// The industries the product knows — ONE list for the two columns that carry
// it: `listings.space_type` (validated by functions/listings) and
// `orgs.space_type` (written by PATCH /me/brand, read by org_entitlement() for
// the industry-aware trial, migration 0044). The database CHECK constraint on
// orgs.space_type (0044) and the iOS `SpaceType` enum (Models/Listing.swift)
// carry the same six values; a seventh is a deliberate edit in all three.
//
// coach/prompt.ts and ai-chapters/prompt.ts keep their own copies because
// they attach vocabularies to the values; the VALUES must stay identical.

export const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
export type SpaceType = typeof SPACE_TYPES[number];

/** True when `raw` is exactly one of the known industries (no coercion). */
export function isSpaceType(raw: unknown): raw is SpaceType {
  return typeof raw === "string" && (SPACE_TYPES as readonly string[]).includes(raw);
}
