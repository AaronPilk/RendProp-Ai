// ai_routes.params — reading operator-supplied vendor knobs SAFELY.
//
// `params` (migration 0030) is a jsonb column on a route row. It exists because
// two models on the same task do not want the same request shape: the classifier
// steps this router started with want `reasoning.effort:"none"` and a 300-token
// ceiling, and a reasoning model sold for hard work is crippled — or outright
// refused — by exactly that. Before 0030 those were CONSTANTS in the adapters,
// so adding a model with a different shape was a deploy. Now it is a row.
//
// ── THE ONE RULE ────────────────────────────────────────────────────────────
//
// A params blob is OPERATOR-SUPPLIED CONFIG THAT REACHES A VENDOR'S API. It is
// not tenant input — `ai_routes` is service-role write only (0018 §7) — but it
// is still typed by a human into a database at 2am, and it is forwarded to a
// third party that bills us per token. So:
//
//   • WHITELIST, never passthrough. Every key an adapter acts on is named in
//     that adapter, and every value is checked against the set the vendor
//     actually accepts. An unknown key, a misspelt key, or a legal key holding
//     an illegal value is treated as ABSENT.
//   • ABSENT MEANS TODAY. Every reader here answers `null` for anything it does
//     not recognise, and every adapter's fallback for `null` is the literal
//     constant it shipped with. That is what makes 0030 additive: the ~70 rows
//     that carry no params behave byte-for-byte as they did.
//   • A CEILING IS STILL A CEILING. `max_output_tokens` is the one knob that
//     can move money, so it is clamped in code as well as chosen in a row —
//     see MAX_PARAM_OUTPUT_TOKENS.
//
// Nothing in here throws. A bad row must degrade to today's behaviour, never
// take a route down.

/**
 * The hard ceiling on any params-supplied output budget, whatever the row says.
 *
 * WHY A CODE CAP AT ALL, when the whole point of 0030 is that the row decides:
 * because a mistyped ceiling is the one params mistake that spends real money
 * silently. On the most expensive text model in the table (gpt-6-astra, $50 per
 * million output tokens) a fat-fingered `128000` — the model's own documented
 * max output, so an entirely plausible thing for someone to paste — would be
 * $6.40 PER CALL on a route that is free to the user and rate-limited only by a
 * 60-per-5-minutes burst key. That is a four-figure afternoon.
 *
 *   8,000 × $50 / 1e6 = $0.40   worst case per call, on the priciest model
 *   2,400                       the largest ceiling this repo actually seeds
 *                               (copy.shotlist: ~1,600 visible + reasoning)
 *
 * So 8,000 is >3x the biggest legitimate ask and bounds the blast radius at
 * roughly half of what `video.aerial_no_photo` already costs per call. A value
 * above it is CLAMPED rather than ignored: the operator asked for more room,
 * and clamping honours that as far as we allow, where ignoring would silently
 * hand them the caller's much smaller default instead.
 *
 * Raising this is a deliberate decision about a COGS ceiling, not a tuning knob.
 */
export const MAX_PARAM_OUTPUT_TOKENS = 8000;

/**
 * Read `key` as one of `allowed`, or null.
 *
 * Case- and whitespace-insensitive, because "Low " in a hand-typed row means
 * "low" and refusing it would be pedantry that silently downgrades a model. A
 * value outside the set is null (→ the adapter's own default), NOT an error:
 * the vendor lists which efforts it accepts and we are not going to find out
 * the hard way, mid-request, on the user's critical path.
 */
export function paramEnum<T extends string>(
  params: Record<string, unknown> | null | undefined,
  key: string,
  allowed: readonly T[],
): T | null {
  const raw = params?.[key];
  if (typeof raw !== "string") return null;
  const v = raw.trim().toLowerCase();
  return (allowed as readonly string[]).includes(v) ? (v as T) : null;
}

/**
 * Read `key` as a positive whole number of tokens, clamped to
 * MAX_PARAM_OUTPUT_TOKENS, or null.
 *
 * Absent, non-numeric, NaN, infinite, zero or negative all read as null so the
 * adapter falls back to what it does today. A fractional value is floored —
 * `1600.5` is a typo, not a request for half a token, and rounding down never
 * costs more than was asked for. Strings are accepted (`"1600"`), because jsonb
 * written by hand or by a console form quotes numbers more often than not, and
 * refusing them would make the column feel broken for no safety gain.
 */
export function paramTokens(
  params: Record<string, unknown> | null | undefined,
  key: string,
): number | null {
  const raw = params?.[key];
  const n = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw.trim()) : NaN;
  if (!Number.isFinite(n) || n < 1) return null;
  return Math.min(Math.floor(n), MAX_PARAM_OUTPUT_TOKENS);
}
