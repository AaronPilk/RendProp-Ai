import { uuid } from "../../data/contracts";

export const clientCardFields = ["name", "title", "brokerage", "phone", "email", "website", "instagram", "linkedin"] as const;
export type ClientCard = Partial<Record<typeof clientCardFields[number] | "avatar_url", string>>;
export type ClientContact = { listing_id: string; enabled: boolean; public_card: ClientCard; recipient_email: string; hide_rendprop_branding: boolean; photo_asset_id?: string | null; revision: number; updated_at: string };
export type ClientForm = { enabled: boolean; public_card: Record<typeof clientCardFields[number], string>; recipient_email: string; separate_recipient: boolean; hide_rendprop_branding: boolean; photo_asset_id: string | null; avatar_url: string | null };
const row = (value: unknown): Record<string, unknown> => { if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("The listing contact could not be verified. Refresh before publishing."); return value as Record<string, unknown>; };
const text = (value: unknown, max = 300): string => { if (value === undefined || value === null) return ""; if (typeof value !== "string" || value.length > max || /[\u0000-\u001f\u007f]/.test(value)) throw new Error("The listing contact contains an unreadable field."); return value; };
export function contactHTTPS(value: string): string | null { try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password ? url.href : null; } catch { return null; } }
export function contactEmail(value: string): boolean { return value.length <= 200 && /^[^\s@?&#]+@[^\s@?&#]+\.[^\s@?&#]+$/.test(value); }
export function decodeClientContact(raw: unknown, listingId: string): ClientContact | null {
  const value = row(raw).contact;
  if (value === null) return null;
  const contact = row(value), card = row(contact.public_card);
  if (uuid(contact.listing_id) !== uuid(listingId) || typeof contact.enabled !== "boolean" || typeof contact.hide_rendprop_branding !== "boolean" || !Number.isSafeInteger(contact.revision) || Number(contact.revision) < 1) throw new Error("This contact belongs to another property or an unreadable revision.");
  const public_card: ClientCard = {};
  for (const key of clientCardFields) { const value = text(card[key]); if (value) public_card[key] = value; }
  const avatar = text(card.avatar_url, 4096);
  if (avatar && !contactHTTPS(avatar)) throw new Error("The contact photo could not be verified.");
  if (avatar) public_card.avatar_url = avatar;
  const recipient_email = text(contact.recipient_email, 200), updated_at = text(contact.updated_at);
  if (contact.enabled && (!public_card.name?.trim() || !contactEmail(recipient_email)) || !Number.isFinite(Date.parse(updated_at))) throw new Error("The client contact is incomplete. Refresh before publishing.");
  return { listing_id: listingId, enabled: contact.enabled, public_card, recipient_email, hide_rendprop_branding: contact.hide_rendprop_branding, photo_asset_id: contact.photo_asset_id == null ? null : uuid(contact.photo_asset_id), revision: Number(contact.revision), updated_at };
}
export function clientForm(contact: ClientContact | null): ClientForm {
  const public_card = Object.fromEntries(clientCardFields.map(key => [key, contact?.public_card[key] ?? ""])) as ClientForm["public_card"];
  return { enabled: contact?.enabled ?? false, public_card, recipient_email: contact?.recipient_email ?? "", separate_recipient: !!contact?.recipient_email && contact.recipient_email.toLowerCase() !== public_card.email.toLowerCase(), hide_rendprop_branding: contact?.hide_rendprop_branding ?? true, photo_asset_id: contact?.photo_asset_id ?? null, avatar_url: contact?.public_card.avatar_url ?? null };
}
export function clientContactPayload(form: ClientForm, revision: number) {
  if (!Number.isSafeInteger(revision) || revision < 0) throw new Error("Refresh the listing contact before saving.");
  const public_card: ClientCard = {};
  for (const key of clientCardFields) { const value = form.public_card[key].trim(); if (value.length > 300 || /[\u0000-\u001f\u007f]/.test(value)) throw new Error("Use single-line contact details up to 300 characters."); if (value) public_card[key] = value; }
  const recipient_email = (form.separate_recipient ? form.recipient_email : form.public_card.email).trim().toLowerCase();
  if (form.enabled) {
    if (!public_card.name || public_card.name.length > 120 || public_card.name.includes("@")) throw new Error("Enter your client’s name or business name, up to 120 characters.");
    if (!contactEmail(recipient_email)) throw new Error("Enter the email address that should receive this client’s leads.");
    if (public_card.email && !contactEmail(public_card.email)) throw new Error("Enter a valid public contact email.");
    if (public_card.phone && !/^[+()\d\s.-]{7,40}$/.test(public_card.phone)) throw new Error("Enter a valid public phone number.");
    for (const key of ["website", "instagram", "linkedin"] as const) if (public_card[key] && !contactHTTPS(public_card[key]!)) throw new Error("Use a complete https:// address for website and social links.");
  }
  return { expected_revision: revision, enabled: form.enabled, public_card, recipient_email, hide_rendprop_branding: form.hide_rendprop_branding, photo_asset_id: form.photo_asset_id === null ? null : uuid(form.photo_asset_id) };
}
