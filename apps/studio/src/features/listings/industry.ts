export type IndustryField = { key: string; label: string; type?: "number" | "url" | "tel"; multiline?: boolean; options?: readonly string[]; help?: string };
// Wire keys match the phone's DetailFieldsEditor and the per-field facts RPC.
// Lists remain comma-separated strings; unknown or typed saved values are never
// normalized merely because a form was opened.
export const INDUSTRY_FIELDS: Record<string, readonly IndustryField[]> = {
  venue: [
    { key: "capacitySeated", label: "Max seated guests", type: "number" }, { key: "capacityStanding", label: "Max standing guests", type: "number" },
    { key: "startingPrice", label: "Starting price", type: "number" }, { key: "eventTypes", label: "Event types", help: "Separate event types with commas." },
    { key: "catering", label: "Catering", options: ["In-house", "In-house or outside", "Outside only", "None"] },
    { key: "spaceSetting", label: "Indoor / Outdoor", options: ["Indoor", "Outdoor", "Both"] }, { key: "amenities", label: "Amenities", help: "Separate amenities with commas." },
    { key: "bookingUrl", label: "Booking / inquiry link", type: "url" },
  ],
  restaurant: [
    { key: "cuisineType", label: "Cuisine", help: "Separate cuisine types with commas." }, { key: "priceRange", label: "Price range", options: ["$", "$$", "$$$", "$$$$"] },
    { key: "hours", label: "Hours", multiline: true }, { key: "reservationUrl", label: "Reservations link", type: "url" }, { key: "menuUrl", label: "Menu link", type: "url" },
    { key: "amenities", label: "Features", help: "Separate features with commas." }, { key: "phone", label: "Business phone", type: "tel" },
  ],
  retail: [
    { key: "storeCategory", label: "Store type", options: ["Grocery", "Convenience", "Specialty Food", "Bakery", "Liquor / Wine", "Pharmacy", "Apparel", "Home & Hardware", "Boutique", "General Retail"] },
    { key: "hours", label: "Hours", multiline: true }, { key: "phone", label: "Business phone", type: "tel" }, { key: "onlineStoreUrl", label: "Online store / website", type: "url" },
    { key: "weeklySpecial", label: "Weekly special / promo", multiline: true }, { key: "shoppingOptions", label: "How to shop", help: "Separate options with commas." }, { key: "departments", label: "Departments", help: "Separate departments with commas." },
  ],
  fitness: [
    { key: "facilityType", label: "Facility type", options: ["Gym", "Yoga Studio", "CrossFit", "Boutique / Classes", "Pilates", "Martial Arts"] },
    { key: "membershipPrice", label: "Membership per month", type: "number" }, { key: "dayPassPrice", label: "Day pass", type: "number" },
    { key: "is247", label: "Open 24/7", options: ["true", "false"] }, { key: "hours", label: "Hours", multiline: true },
    { key: "amenities", label: "Amenities", help: "Separate amenities with commas." }, { key: "freeTrialOffer", label: "Free trial / intro offer" }, { key: "bookingUrl", label: "Booking / schedule link", type: "url" },
  ],
  other: [{ key: "hours", label: "Hours", multiline: true }, { key: "phone", label: "Business phone", type: "tel" }, { key: "website", label: "Website", type: "url" }],
};
export function industryFields(spaceType: string): readonly IndustryField[] { return INDUSTRY_FIELDS[spaceType] ?? []; }
export function detailFormValue(value: unknown): string { return value == null ? "" : typeof value === "string" ? value : typeof value === "number" || typeof value === "boolean" ? String(value) : ""; }
export function detailInputs(details: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries([...new Set(Object.values(INDUSTRY_FIELDS).flatMap(fields => fields.map(field => field.key)))].map(key => [`detail.${key}`, detailFormValue(details[key])]));
}
export function detailChanges(form: FormData, details: Record<string, unknown>) {
  const expected: Record<string, unknown> = {}, changes: Record<string, unknown> = {};
  const fields = new Map(Object.values(INDUSTRY_FIELDS).flatMap(items => items.map(field => [field.key, field] as const)));
  for (const [name, raw] of form) {
    if (!name.startsWith("detail.")) continue;
    const key = name.slice(7), field = fields.get(key);
    if (!field) throw new Error("This business detail cannot be saved here.");
    const value = String(raw).trim();
    if (value === detailFormValue(details[key]).trim()) continue;
    if (value.length > 2000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value)) throw new Error(`Use shorter text for ${field.label}.`);
    if (value && field.type === "number" && (!Number.isFinite(Number(value)) || Number(value) < 0)) throw new Error(`Enter a non-negative ${field.label.toLowerCase()}.`);
    if (value && field.type === "url") {
      let url: URL; try { url = new URL(value); } catch { throw new Error(`${field.label} must be an https link.`); }
      if (url.protocol !== "https:" || url.username || url.password || /[\s\\]/.test(value)) throw new Error(`${field.label} must be an https link.`);
    }
    changes[key] = value || null;
    expected[key] = { present: Object.hasOwn(details, key), value: Object.hasOwn(details, key) ? details[key] : null };
  }
  return { expected, changes };
}
