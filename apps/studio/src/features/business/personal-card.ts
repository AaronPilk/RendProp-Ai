import { record } from "./model";
export const PERSONAL_FIELDS = ["name", "title", "brokerage", "phone", "email", "website", "instagram", "linkedin", "tiktok"] as const;
export type PersonalKey = typeof PERSONAL_FIELDS[number];
export type PersonalCard = { userId: string; spaceType: string | null; card: Partial<Record<PersonalKey, string>> | null };
export function decodePersonalCard(raw: unknown, actor: string): PersonalCard {
  const r = record(raw);
  if (r.ok !== true || r.user_id !== actor || !(r.space_type === null || ["real_estate", "venue", "restaurant", "retail", "fitness", "other"].includes(String(r.space_type)))) throw new Error("Your personal card could not be confirmed. Reload it before saving.");
  const card = r.public_card === null ? null : record(r.public_card);
  if (card && Object.entries(card).some(([key, value]) => !(PERSONAL_FIELDS as readonly string[]).includes(key) || typeof value !== "string")) throw new Error("Your personal card could not be read. Reload it before saving.");
  return { userId: actor, spaceType: r.space_type as string | null, card: card as PersonalCard["card"] };
}
export function personalCardBody(saved: PersonalCard, values: Record<PersonalKey, string>, spaceType: string) {
  const original: Record<string, unknown> = { ...saved.card, ...(saved.spaceType === null ? {} : { space_type: saved.spaceType }) };
  const changes: Record<string, string | null> = {}, expected: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries({ ...values, space_type: spaceType })) {
    const value = raw.trim();
    if (value === String(original[key] ?? "")) continue;
    changes[key] = value || null;
    expected[key] = Object.hasOwn(original, key) ? { present: true, value: original[key] } : { present: false };
  }
  return { changes, expected };
}
export function personalCardValues(card: PersonalCard): Record<PersonalKey, string> {
  return Object.fromEntries(PERSONAL_FIELDS.map(key => [key, card.card?.[key] ?? ""])) as Record<PersonalKey, string>;
}
export function personalCardConfirmed(saved: PersonalCard, changes: Record<string, string | null>): boolean {
  return Object.entries(changes).every(([key,value]) => key === "space_type" ? saved.spaceType === value : value === null ? !Object.hasOwn(saved.card ?? {},key) : saved.card?.[key as PersonalKey] === value);
}
