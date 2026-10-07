import { StudioError } from "./config";
export type PhotoPackage = {
  orgId: string; startsAt: string; endsAt: string;
  photos: { cap: number; used: number; remaining: number };
  otherAI: { capCents: number; usedCents: number; remainingCents: number };
};
export function decodePhotoPackage(value: unknown, orgId: string, now = Date.now()): PhotoPackage | null {
  if (value == null) return null;
  const invalid = (): never => { throw new StudioError("invalid-response", "Your photo allowance could not be verified. Refresh before starting new work."); };
  if (!value || typeof value !== "object" || Array.isArray(value)) return invalid();
  const row = value as Record<string, unknown>;
  if (row.org_id !== orgId) throw new StudioError("identity-mismatch", "This photo allowance belongs to a different workspace. Reload Studio.");
  const integer = (v: unknown, max: number): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && v <= max;
  const timestamp = (v: unknown): v is string => typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(v) && Number.isFinite(Date.parse(v));
  const p = row.photo_admissions as Record<string, unknown> | null, a = row.other_ai as Record<string, unknown> | null;
  if (row.policy !== "one-gemini-1k-4096-plus-one-kontext-20261007" || row.tariff_version !== "published-standard-20261006"
    || !timestamp(row.starts_at) || !timestamp(row.ends_at) || Date.parse(row.starts_at) > now || Date.parse(row.ends_at) <= now
    || !p || !integer(p.cap,10000) || !integer(p.used,10000) || !integer(p.remaining,10000) || p.used > p.cap || p.remaining !== p.cap-p.used
    || row.photo_hold_cents !== 35.1296 || row.protected_photo_cents !== Math.ceil(p.cap*35.1296)
    || !a || !integer(a.cap_cents,100000000) || !integer(a.used_cents,100000000) || !integer(a.remaining_cents,100000000)
    || a.used_cents > a.cap_cents || a.remaining_cents !== a.cap_cents-a.used_cents) return invalid();
  return { orgId, startsAt: row.starts_at, endsAt: row.ends_at, photos: {cap:p.cap,used:p.used,remaining:p.remaining},
    otherAI: {capCents:a.cap_cents,usedCents:a.used_cents,remainingCents:a.remaining_cents} };
}
