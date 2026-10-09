// coach — Rendprop's in-app COACH (owner-authenticated).
//
//   POST /coach { messages:[{role,content}], space_type?, context?:{
//                  listings:[{id,title,has_video,room_tags,has_tour,
//                             published,photos,edits,reels}], plan?, screen? } }
//     → { reply, actions:[{type,label,listing_id?}], suggested_replies:[string], model }
//
// Full contract: docs/COACH-CONTRACT.md
//
// TWO JOBS, in the same endpoint: (a) walk a brand-new user through their
// first project one step at a time — "I have a listing at 123 Main St and I
// want a tour and a reel" → the coach asks only what it's missing, then gives
// ONE step with a tap-to-go action; (b) answer customer-service questions
// from the fixed knowledge base in knowledge.ts. Job (b) is the higher
// priority of the two — see prompt.ts's system instruction — because a
// support question with no answer is a support ticket, and this feature
// exists to take load off that ticket queue, not add to it.
//
// ── THREE THINGS THIS FUNCTION IS CAREFUL ABOUT ─────────────────────────────
//
//  1. NEVER DEAD, EVEN WITH THE ROUTER FLAG OFF (today's default). coach.chat
//     is a BRAND NEW task — unlike ai-chapters/ai-photo it has no shipped
//     "legacy" behaviour to preserve, so it seeds no `note='legacy'` row
//     (migration 0023). With the flag off, `resolveRoute()` finds no rows for
//     this task and answers `[]`; rather than the single hardcoded step every
//     other function's flag-off path falls back to (which would leave this
//     one feature with NO cross-provider failover precisely while the master
//     flag is off — most of the time, in practice), `chooseChain()` below
//     substitutes its own TWO-step fallback (anthropic then openai, the exact
//     pair migration 0023 seeds) so a single vendor outage never takes the
//     coach down. `runChain()` still drives it, still reports every attempt
//     to the circuit breaker, and once the flag is on the real seeded rows
//     replace this fallback outright (rule 2, docs/AI-ROUTER-CONTRACT.md:
//     never re-filter what resolveRoute hands back).
//
//  2. NO PLAN METERING, EVER. Customer service and first-project onboarding
//     are free on every plan by product decision (see the task brief and
//     0023's header) — there is no paid-plan allowance or monthly cap here,
//     only durable user and workspace safety limits (abuse protection, not a
//     paid allowance, and never refunded on a failed generation the way the
//     precious monthly quotas elsewhere in this codebase are).
//
//  3. TEXT ONLY, NEVER LOGGED. No photo or video is ever part of a coach
//     request — `context.listings[]` carries bounded device hints; context.ts
//     verifies cloud ids and loads only selected-workspace counts, closed states
//     and limited account/usage fields. Message content is never in a log line, in either
//     direction — only ids, counts, provider/model names and error classes.

import { handleOptions } from "../_shared/cors.ts";
import {
  assert,
  HttpError,
  json,
  pathSegments,
  readJsonLimited,
  respondError,
} from "../_shared/http.ts";
import {
  adminClient,
  assertPaidAiIdentity,
  getUser,
  orgForUser,
  preferredOrg,
  userClient,
} from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { entitlementFor, type Entitlement } from "../_shared/entitlements.ts";
import { recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { resolveRoute } from "../_shared/router.ts";
import { runChain } from "../_shared/providers/chain.ts";
import { fundingContext, fundedAttempt, textAttemptQuote, completeFundingOperation } from "../_shared/funded-serving.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { anthropicMessages } from "../_shared/providers/anthropic.ts";
import { openaiChat } from "../_shared/providers/openai.ts";

import {
  buildUserTurn,
  type CoachContext,
  type CoachListingCtx,
  screenOf,
  spaceTypeOf,
  systemInstruction,
} from "./prompt.ts";
import { parseCoachOutput } from "./actions.ts";
import { coachContext } from "./context.ts";

// ── Tunables ─────────────────────────────────────────────────────────────────

/** 12 messages / 5 min and 60 / day, PER USER — abuse protection on an
 *  always-free feature, not a plan quota (see header, point 2). */
const BURST_MAX_PER_WINDOW = 12;
const BURST_WINDOW_SECONDS = 300;
const DAY_MAX_PER_WINDOW = 60;
const DAY_WINDOW_SECONDS = 86400;
/** Shared workspace safety fence; free access is independent of paid allowances. */
const ORG_DAY_MAX_PER_WINDOW = 600;

/** Keep the reply short and the bill small — a coaching message, not an essay. */
const MAX_TOKENS = 600;

/** Sliding window: only the most recent turns are sent, oldest dropped first.
 *  Bounds token cost regardless of how long a chat session runs. */
const MAX_HISTORY_MESSAGES = 16;
const MAX_MESSAGE_CHARS = 1200;

const MAX_LISTINGS = 25;
const MAX_TITLE_CHARS = 120;
const KNOWN_PLANS = [
  "free",
  "trial",
  "starter",
  "solo",
  "pro",
  "team",
  "brokerage",
] as const;

// Where the coach was opened from. A CLOSED SET, like KNOWN_PLANS and the
// action enum — not a length-capped free string. `screen` is a hint to the
// model AND it lands in `cost_ledger.meta`, a durable row every member of the
// org can read under the "org ledger" RLS policy; a free string there is a
// 40-character channel from one member into everyone else's billing history,
// which is exactly what the events vocabulary + scrubber exist to prevent for
// analytics. Anything unrecognised becomes null. Add a value here when the app
// adds an entry point (apps/ios/Rendprop/Coach/CoachView.swift call sites).
// The complete native AskAIScreen vocabulary is kept in prompt.ts and tested
// against the Swift enum. It remains a closed set, never arbitrary ledger text.

// ── The two-step fallback (see header, point 1) — MUST match migration
// 0023_coach_routes.sql's seeded rows exactly, so the flag-off path and the
// flag-on path price and route identically. ────────────────────────────────

const ANTHROPIC_FALLBACK: RouteStep = {
  route_id: "coach-chat-fallback-anthropic",
  task: "coach.chat",
  provider: "anthropic",
  model: "claude-sonnet-5",
  unit: "call",
  unit_cents: 2.1,
  capabilities: ["text", "chat"],
  max_latency_s: 30,
  min_plan: "free",
  same_model_as: null,
  privacy_tier: "retained_30d",
  enabled: true,
};

const OPENAI_FALLBACK: RouteStep = {
  route_id: "coach-chat-fallback-openai",
  task: "coach.chat",
  provider: "openai",
  model: "gpt-5.6-terra",
  unit: "call",
  unit_cents: 2.0,
  capabilities: ["text", "chat"],
  max_latency_s: 30,
  min_plan: "free",
  same_model_as: null,
  privacy_tier: "retained_30d",
  enabled: true,
};

/**
 * Resolve today's chain for coach.chat. `resolveRoute` itself never throws
 * (it is designed to fail toward its own legacy step — see router.ts), so the
 * try/catch here is belt-and-braces, not the primary safety net.
 */
async function chooseChain(plan: string): Promise<RouteStep[]> {
  try {
    const steps = await resolveRoute("coach.chat", {
      plan,
      needs: ["text", "chat"],
    });
    if (steps.length > 0) return steps; // used AS RETURNED — never re-filtered
  } catch (e) {
    console.error(
      "coach: resolveRoute threw; using the two-step fallback:",
      e instanceof Error ? e.name : "unknown",
    );
  }
  return [ANTHROPIC_FALLBACK, OPENAI_FALLBACK];
}

async function trustedEntitlement(orgId: string): Promise<Entitlement | null> {
  try {
    return await entitlementFor(orgId);
  } catch {
    return null;
  }
}

// ── Body validation — every field is untrusted, nothing is a UUID here ──────
//
// Client context is untrusted. context.ts verifies cloud row ids under the
// selected org and excludes unavailable/foreign rows. Device route ids remain
// distinct from server ids; local drafts are explicitly labelled device hints.

interface CoachMessageIn {
  role?: unknown;
  content?: unknown;
}

interface CoachListingIn {
  id?: unknown;
  server_id?: unknown;
  local_draft?: unknown;
  title?: unknown;
  has_video?: unknown;
  room_tags?: unknown;
  has_tour?: unknown;
  published?: unknown;
  photos?: unknown;
  edits?: unknown;
  reels?: unknown;
  attention?: unknown;
}

interface CoachBody {
  messages?: CoachMessageIn[];
  space_type?: unknown;
  context?: {
    listings?: CoachListingIn[];
    plan?: unknown;
    screen?: unknown;
    selected_listing_id?: unknown;
  };
}

type CleanMessage = { role: "user" | "assistant"; content: string };

function cleanMessages(raw: unknown): CleanMessage[] {
  if (!Array.isArray(raw)) return [];
  const out: CleanMessage[] = [];
  for (const m of raw) {
    if (!m || typeof m !== "object") continue;
    const o = m as CoachMessageIn;
    if (o.role !== "user" && o.role !== "assistant") continue;
    if (typeof o.content !== "string") continue;
    const trimmed = o.content.trim().slice(0, MAX_MESSAGE_CHARS);
    if (!trimmed) continue;
    out.push({ role: o.role, content: trimmed });
  }
  return out.slice(-MAX_HISTORY_MESSAGES);
}

function nonNegInt(v: unknown): number {
  const n = Math.round(Number(v));
  return Number.isFinite(n) && n > 0 ? Math.min(n, 9999) : 0;
}

function cleanListings(raw: unknown): CoachListingCtx[] {
  if (!Array.isArray(raw)) return [];
  const out: CoachListingCtx[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (out.length >= MAX_LISTINGS) break;
    if (!item || typeof item !== "object") continue;
    const o = item as CoachListingIn;
    const id = typeof o.id === "string" ? o.id.trim().toLowerCase() : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      serverID: typeof o.server_id === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(o.server_id.trim()) ? o.server_id.trim().toLowerCase() : null,
      localDraft: o.local_draft === true && o.server_id == null,
      title: typeof o.title === "string"
        ? o.title.trim().slice(0, MAX_TITLE_CHARS)
        : "",
      hasVideo: o.has_video === true,
      roomTags: nonNegInt(o.room_tags),
      hasTour: o.has_tour === true,
      published: o.published === true,
      photos: nonNegInt(o.photos),
      edits: nonNegInt(o.edits),
      reels: nonNegInt(o.reels),
      attention: ["cloud_access", "facts_review", "upload", "render", "publish", "unknown"].includes(String(o.attention)) ? String(o.attention) : null,
    });
  }
  return out;
}

function cleanPlan(raw: unknown): string {
  const s = String(raw ?? "").trim().toLowerCase();
  return (KNOWN_PLANS as readonly string[]).includes(s) ? s : "free";
}

function cleanScreen(raw: unknown): string | null {
  return screenOf(raw);
}

// ── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "coach");
    if (req.method !== "POST" || seg.length !== 0) {
      throw new HttpError(404, "Not found: POST /coach", "not_found");
    }

    // Auth FIRST, like every owner route: signed-out is a plain 401, and the
    // app's own CoachModel answers from CoachOffline instead (never dead).
    const user = await getUser(req);

    const body = await readJsonLimited<CoachBody>(req, 65_536);
    const messages = cleanMessages(body.messages);
    assert(
      messages.length > 0 && messages[messages.length - 1].role === "user",
      400,
      "messages must be a non-empty array ending in a user message",
    );

    // Resolve membership before any paid work. Client plan hints cannot select
    // a premium route, and a missing workspace cannot produce unaccounted spend.
    const requestedOrg = preferredOrg(req)?.trim().toLowerCase();
    assert(
      requestedOrg,
      409,
      "Choose a workspace before using online Coach.",
      "conflict",
    );
    assert(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
        requestedOrg,
      ),
      400,
      "Invalid workspace identity.",
      "validation",
    );
    const orgId = await orgForUser(user.id, requestedOrg);
    await assertPaidAiIdentity(user, orgId);
    const entitlement = await trustedEntitlement(orgId);
    const plan = !entitlement || entitlement.degraded ? "free" : cleanPlan(entitlement.plan);
    const space = spaceTypeOf(body.space_type);
    const selected = typeof body.context?.selected_listing_id === "string" ? body.context.selected_listing_id.trim().toLowerCase() : null;
    const verified = await coachContext(userClient(req), adminClient(), user.id, orgId, entitlement, cleanListings(body.context?.listings), selected);
    const context: CoachContext = {
      ...verified,
      plan,
      screen: cleanScreen(body.context?.screen),
    };
    const validListingIds = new Set(context.listings.map((l) => l.id));

    // Rate limits, PER USER, charged before the provider call (same order as
    // every other durable limiter in this codebase) — see header, point 2.
    if (
      !(await durableRateLimit(
        `coachburst:${user.id}`,
        BURST_MAX_PER_WINDOW,
        BURST_WINDOW_SECONDS,
      ))
    ) {
      throw new HttpError(
        429,
        "That's a lot of messages at once — try again in a few minutes.",
        "rate_limited",
      );
    }
    if (
      !(await durableRateLimit(
        `coachday:${user.id}`,
        DAY_MAX_PER_WINDOW,
        DAY_WINDOW_SECONDS,
      ))
    ) {
      throw new HttpError(
        429,
        "You've reached today's message limit for the coach — try again tomorrow.",
        "rate_limited",
      );
    }
    if (
      !(await durableRateLimit(
        `coachorgday:${orgId}`,
        ORG_DAY_MAX_PER_WINDOW,
        DAY_WINDOW_SECONDS,
      ))
    ) {
      throw new HttpError(
        429,
        "Your workspace has reached today's coach message limit — try again tomorrow.",
        "rate_limited",
      );
    }

    const system = systemInstruction(space);
    const userTurn = buildUserTurn({ space, context, history: messages });

    const chain = await chooseChain(context.plan);

    const funding = await fundingContext(user.id, orgId, req, body, (name, args) => adminClient().rpc(name, args));
    const attempt = await runChain("coach.chat", chain, (step) => fundedAttempt(funding, `coach.chat:${chain.indexOf(step)}`, step, {system, userTurn}, textAttemptQuote(step, system, userTurn, MAX_TOKENS), async () => {
      if (step.provider === "anthropic") {
        // The STEP, not step.model: that is what carries the row's `params`
        // (migration 0030) into the request. No coach.chat row seeds any, so
        // this is byte-identical today and stays a row edit tomorrow.
        return await anthropicMessages({
          model: step,
          system,
          content: [{ type: "text", text: userTurn }],
          maxTokens: MAX_TOKENS,
        });
      }
      if (step.provider === "openai") {
        // One user-role message carrying both the system rules and the turn —
        // the same shape openaiJudge() already uses in _shared/providers/openai.ts.
        // `json: true` asks the Responses API for a syntactically-valid JSON
        // object outright; parseCoachOutput() still re-validates every field,
        // because "valid JSON" is not the same thing as "safe to execute".
        return await openaiChat(
          step,
          [{
            role: "user",
            content: [{
              type: "input_text",
              text: `${system}\n\n---\n\n${userTurn}`,
            }],
          }],
          { maxOutputTokens: MAX_TOKENS, json: true },
        );
      }
      // A future admin-added row this deploy doesn't know how to speak. "other"
      // (not "validation") so runChain() tries the NEXT step instead of
      // hard-failing the whole request over one unrecognised row.
      throw new ProviderError(
        step.provider,
        "other",
        `coach.chat: no adapter for provider "${step.provider}" in this deploy`,
      );
    }));

    const output = parseCoachOutput(attempt.value, validListingIds);

    // Ledger — best effort: the user is waiting on `output` above, which is
    // already computed. A ledger insert failure must never turn a good reply
    // into an error (header, point 2 — this feature has no quota to protect).
    try {
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "coach",
        step: attempt.step,
        meta: {
          request_key: funding.requestKey,
          stage: `coach.chat:${chain.indexOf(attempt.step)}`,
          message_count: messages.length,
          listing_count: context.listings.length,
          has_action: output.actions.length > 0,
          screen: context.screen,
        },
      });
    } catch (e) {
      console.error(
        "coach: ledger write failed (reply already computed):",
        e instanceof Error ? e.name : "unknown",
      );
    }

    return json(await completeFundingOperation(funding, {
      reply: output.reply,
      actions: output.actions,
      suggested_replies: output.suggested_replies,
      model: attempt.step.model,
    }));
  } catch (err) {
    if (!(err instanceof HttpError) || err.status >= 500) {
      return respondError(new HttpError(503, "Online Coach is temporarily unavailable. Your saved work is unchanged; use the app's local help or try again later.", "upstream"));
    }
    return respondError(err);
  }
});
