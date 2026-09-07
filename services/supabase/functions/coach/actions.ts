// coach — the action enum, the model's output format, and the parser/sanitizer
// that turns raw model text into something the app can safely execute.
//
// PURE (no env, no network, no Supabase) so `deno test` on this file alone
// proves the parser without standing up a server — see actions_test.ts.
//
// WHY A CLOSED ENUM. The model NEVER gets to invent a destination. It picks
// from exactly the ten actions below, and the app maps each one to a SCREEN
// THAT ALREADY EXISTS (docs/COACH-CONTRACT.md). A model that could emit
// arbitrary strings could eventually be prompted into fabricating a feature
// ("open_drone_pilot") that the app then has nothing to do with — the enum
// makes that class of bug impossible rather than merely unlikely.

/** The closed action enum. Keep this in lockstep with `CoachAction` on iOS
 *  (Coach/CoachModel.swift) and docs/COACH-CONTRACT.md — three independent
 *  copies by necessity (server/iOS/docs can't share a source file), so a
 *  fourth action added here without the other two is a contract break. */
export const ACTION_TYPES = [
  "start_project",
  "open_tour",
  "open_photos",
  "open_reel",
  "open_floor_plan",
  "open_aerial",
  "share_tour",
  "open_plan_usage",
  "open_support",
  "open_home",
] as const;

export type ActionType = typeof ACTION_TYPES[number];

function isActionType(v: unknown): v is ActionType {
  return typeof v === "string" && (ACTION_TYPES as readonly string[]).includes(v);
}

/** Actions that name a specific project — `listing_id` must be one of the ids
 *  the CALLER sent in `context.listings` (never merely "looks like a UUID"). */
export const LISTING_ACTIONS: ReadonlySet<ActionType> = new Set([
  "open_tour",
  "open_photos",
  "open_reel",
  "open_floor_plan",
  "open_aerial",
  "share_tour",
]);

/** A short, sane label the app can show on the chip even if the model's own
 *  label was missing, empty, or absurdly long. Mirrors CoachAction.defaultLabel
 *  on iOS — see the lockstep note above. */
const DEFAULT_LABEL: Record<ActionType, string> = {
  start_project: "Start my first project",
  open_tour: "Open the tour",
  open_photos: "Open Photo Studio",
  open_reel: "Make a reel",
  open_floor_plan: "Open floor plan",
  open_aerial: "Make an aerial shot",
  share_tour: "Share the tour",
  open_plan_usage: "Open Plan & usage",
  open_support: "Contact support",
  open_home: "Go to Home",
};

export interface CoachAction {
  type: ActionType;
  label: string;
  listing_id?: string;
}

export interface CoachOutput {
  reply: string;
  actions: CoachAction[];
  suggested_replies: string[];
}

// ── Bounds (mirrors the ≤ 80-word / one-action coaching style — prompt.ts
// asks for this; these are the server-side backstop when a model overshoots) ──

const MAX_REPLY_CHARS = 700;
const MAX_LABEL_CHARS = 40;
const MAX_ACTIONS = 1; // "exactly one primary action" — enforced, not just asked for
const MAX_SUGGESTIONS = 4;
const MAX_SUGGESTION_CHARS = 60;

/** Shown when the model's own reply is unusable (empty, or the whole response
 *  failed to parse) — the chat must never render nothing (never dead). */
export const FALLBACK_REPLY =
  "Sorry, I didn't quite catch that. Could you say it again, or tap Contact support if it keeps happening?";

/**
 * A dollar amount, or the words for one, in the model's own reply. Prices
 * come from StoreKit ONLY (Products.swift, `Product.displayPrice`) — never
 * from an LLM, which can misquote, go stale the day a price point changes, or
 * quote the wrong region. This is the server-side BACKSTOP for that hard
 * rule (the system prompt already asks for it — see prompt.ts) — belt and
 * braces, the same shape as this codebase's own fair-housing re-check
 * (ai-chapters/postprocess.ts) rather than trusting one instruction alone.
 * Deliberately broad (a rare false positive just redirects to Plan & usage,
 * which is always a safe, true answer) rather than narrow.
 */
const PRICE_PATTERN = /\$\s?\d|\bUSD\b|\bdollars?\b|\bcents?\b/i;

const PRICE_SAFE_REPLY = "I can't quote a price here — plans, usage and the live price are in Plan & usage.";

// ── Step 1: pull a JSON object out of raw model text ────────────────────────

/**
 * The model is asked to return ONLY a JSON object. Real models sometimes wrap
 * it in a ```json fence anyway (the same habit `anthropicJudge`/`openaiJudge`
 * already work around in _shared/providers/*.ts), and occasionally add a
 * sentence before or after it despite the instruction not to. This:
 *   1. strips a fence if present,
 *   2. tries a straight JSON.parse,
 *   3. falls back to the FIRST balanced {...} substring in the text.
 * Returns null only when no JSON object could be found anywhere in the text —
 * the caller then falls back to FALLBACK_REPLY rather than throwing.
 */
export function extractJsonObject(raw: string): Record<string, unknown> | null {
  const text = String(raw ?? "").trim();
  if (!text) return null;

  const unfenced = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

  for (const candidate of [unfenced, text]) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // fall through to the balanced-brace scan below
    }
  }

  // Balanced-brace scan: find a `{`, then the matching `}` that closes it
  // (tracking string literals so a brace inside a quoted string doesn't end the
  // scan early). Handles "Sure! {...}" and "{...}\nLet me know!".
  //
  // It scans EVERY candidate, not just the first. A model that writes prose
  // containing a stray brace ("the format is { like this }: {\"reply\":…}")
  // used to lose its whole answer: the first candidate either failed to parse
  // — and the old code returned null on the spot — or parsed as some
  // incidental `{}` that carried no reply, and the real payload after it was
  // never reached. Both cases ended as the canned fallback with the model's
  // action silently dropped. A candidate now only wins if it parses AND
  // carries a non-empty string `reply`; otherwise the scan resumes at the next
  // `{`. The last resort is the first well-formed object of any shape, which
  // keeps the older, laxer behaviour for replies that legitimately have no
  // `reply` key yet still parse.
  let firstObject: Record<string, unknown> | null = null;
  let start = unfenced.indexOf("{");
  while (start >= 0) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    let end = -1;
    for (let i = start; i < unfenced.length; i++) {
      const ch = unfenced[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end < 0) break;   // unbalanced from here on — nothing later can close
    try {
      const parsed = JSON.parse(unfenced.slice(start, end + 1));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        const record = parsed as Record<string, unknown>;
        if (typeof record.reply === "string" && record.reply.trim()) return record;
        if (!firstObject) firstObject = record;
      }
    } catch {
      // Not JSON — keep looking.
    }
    start = unfenced.indexOf("{", start + 1);
  }
  return firstObject;
}

// ── Step 2: validate + clamp into something the app can trust ──────────────

function cleanText(v: unknown, maxChars: number): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s) return "";
  // Collapse runs of whitespace (models sometimes pad with newlines/tabs) —
  // a chat bubble shows this as-is, so keep it tidy.
  const collapsed = s.replace(/[ \t]*\n[ \t]*/g, "\n").replace(/[ \t]{2,}/g, " ");
  return collapsed.length > maxChars ? collapsed.slice(0, maxChars).trim() : collapsed;
}

/**
 * Turn a parsed (but untrusted) object into a `CoachOutput` the app can
 * execute blindly:
 *   • `reply` is always a non-empty string (FALLBACK_REPLY if the model gave
 *     nothing usable).
 *   • `actions` keeps only entries whose `type` is in the closed enum AND,
 *     for a listing action, whose `listing_id` is one of `validListingIds` —
 *     everything else is DROPPED, never substituted or guessed. Clamped to
 *     `MAX_ACTIONS` (today: 1) — "exactly one primary action" is enforced
 *     here, not just requested in the prompt.
 *   • `suggested_replies` keeps short, non-empty, de-duplicated strings only.
 *
 * Never throws. A completely unusable `parsed` (not an object, or one with no
 * usable `reply`) still returns a valid `CoachOutput` with `FALLBACK_REPLY`
 * and empty actions/suggestions — the chat is never dead.
 */
export function sanitizeCoachOutput(
  parsed: Record<string, unknown> | null,
  validListingIds: ReadonlySet<string>,
): CoachOutput {
  const replyRaw = parsed && typeof parsed === "object" ? parsed["reply"] : undefined;
  const reply = cleanText(replyRaw, MAX_REPLY_CHARS) || FALLBACK_REPLY;

  const actionsRaw = parsed && Array.isArray(parsed["actions"]) ? (parsed["actions"] as unknown[]) : [];
  const actions: CoachAction[] = [];
  for (const raw of actionsRaw) {
    if (actions.length >= MAX_ACTIONS) break;
    if (!raw || typeof raw !== "object") continue;
    const o = raw as Record<string, unknown>;
    if (!isActionType(o.type)) continue; // out-of-enum — dropped, never coerced
    const type = o.type;

    let listingId: string | undefined;
    if (LISTING_ACTIONS.has(type)) {
      const idRaw = typeof o.listing_id === "string" ? o.listing_id.trim() : "";
      if (!idRaw || !validListingIds.has(idRaw)) continue; // dropped, not substituted
      listingId = idRaw;
    }

    const label = cleanText(o.label, MAX_LABEL_CHARS) || DEFAULT_LABEL[type];
    actions.push(listingId ? { type, label, listing_id: listingId } : { type, label });
  }

  const suggestionsRaw = parsed && Array.isArray(parsed["suggested_replies"])
    ? (parsed["suggested_replies"] as unknown[])
    : [];
  const seen = new Set<string>();
  const suggestedReplies: string[] = [];
  for (const raw of suggestionsRaw) {
    if (suggestedReplies.length >= MAX_SUGGESTIONS) break;
    const s = cleanText(raw, MAX_SUGGESTION_CHARS);
    const key = s.toLowerCase();
    if (!s || seen.has(key)) continue;
    seen.add(key);
    suggestedReplies.push(s);
  }

  // PRICE BACKSTOP — last, so it overrides whatever the model chose. A price
  // leak forces a safe reply AND redirects the action to Plan & usage,
  // because a user who got this reply was almost certainly asking about
  // pricing and still deserves the one correct next step.
  if (PRICE_PATTERN.test(reply)) {
    return {
      reply: PRICE_SAFE_REPLY,
      actions: [{ type: "open_plan_usage", label: DEFAULT_LABEL.open_plan_usage }],
      suggested_replies: suggestedReplies,
    };
  }

  return { reply, actions, suggested_replies: suggestedReplies };
}

/** Convenience: raw model text → a trustworthy `CoachOutput` in one call. */
export function parseCoachOutput(raw: string, validListingIds: ReadonlySet<string>): CoachOutput {
  return sanitizeCoachOutput(extractJsonObject(raw), validListingIds);
}
