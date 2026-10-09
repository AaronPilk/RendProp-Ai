/** The shared AI budget the server admits work against in ceiling serving
 * mode (`/me` → `serving_envelope`, from `serving_envelope_state`). Absent on
 * funded-mode servers and whenever the server could not compute it; a
 * malformed block is dropped rather than failing the whole account read,
 * because this card is informational — the server is the admission. */
export type ServingEnvelope = {
  kind: string;
  ceilingCents: number;
  spentCents: number;
  heldCents: number;
  availableCents: number;
  periodStart: string | null;
  periodEnd: string | null;
  window: string | null;
  pool: { capCents: number; spentCents: number; endsAt: string | null } | null;
};
const money = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 100_000_000;
const text = (v: unknown): string | null => typeof v === "string" && v.length <= 64 ? v : null;
const timestamp = (v: unknown): string | null => typeof v === "string" && Number.isFinite(Date.parse(v)) ? v : null;
export function decodeServingEnvelope(value: unknown): ServingEnvelope | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const kind = text(row.kind);
  if (!kind || !money(row.ceiling_cents) || !money(row.spent_cents) || !money(row.held_cents) || !money(row.available_cents)
    || row.available_cents > row.ceiling_cents + 0.01) return null;
  let pool: ServingEnvelope["pool"] = null;
  if (row.pool && typeof row.pool === "object" && !Array.isArray(row.pool)) {
    const p = row.pool as Record<string, unknown>;
    if (money(p.cap_cents) && money(p.spent_cents)) pool = { capCents: p.cap_cents, spentCents: p.spent_cents, endsAt: timestamp(p.ends_at) };
  }
  return { kind, ceilingCents: row.ceiling_cents, spentCents: row.spent_cents, heldCents: row.held_cents, availableCents: row.available_cents,
    periodStart: timestamp(row.period_start), periodEnd: timestamp(row.period_end), window: text(row.window), pool };
}
/** Spend and holds round up; what is left rounds down — never promise a cent
 * the server would refuse. */
export function envelopeMoney(cents: number, up = true): string {
  const whole = Math.max(0, up ? Math.ceil(cents) : Math.floor(cents));
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: whole % 100 === 0 ? 0 : 2 }).format(whole / 100);
}
export function envelopeTitle(e: ServingEnvelope): string {
  switch (e.kind) {
    case "free": return "Free AI allowance";
    case "trial": return "Free-trial AI budget";
    case "grace": return "AI budget (billing grace)";
    default: return "AI budget";
  }
}
export function envelopeResetLine(e: ServingEnvelope, format: (iso: string) => string): string | null {
  if (e.kind === "free") return "Lifetime allowance for free workspaces. It does not reset; subscribe for a monthly budget.";
  if (!e.periodEnd) return null;
  const when = format(e.periodEnd);
  switch (e.window) {
    case "trial_window": return `Trial budget ends ${when}.`;
    case "apple_grace": return `Billing grace ends ${when}. Renew to restore the full budget.`;
    case "apple_term": case "apple_slice": case "intro_window": return `Resets ${when} with your subscription period.`;
    default: return `Resets ${when}.`;
  }
}
