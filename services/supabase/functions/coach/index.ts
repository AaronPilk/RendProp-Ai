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
//     0023's header) — there is no entitlement check and no monthly cap here,
//     only the durable PER-USER rate limiter below (abuse protection, not a
//     paid allowance, and never refunded on a failed generation the way the
//     precious monthly quotas elsewhere in this codebase are).
//
//  3. TEXT ONLY, NEVER LOGGED. No photo or video is ever part of a coach
//     request — `context.listings[]` carries only counts and booleans the app
//     already has from AppModel (never queried from the DB here; see
//     prompt.ts). Message content is never in a log line, in either
//     direction — only ids, counts, provider/model names and error classes.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { resolveRoute } from "../_shared/router.ts";
import { runChain } from "../_shared/providers/chain.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { anthropicMessages } from "../_shared/providers/anthropic.ts";
import { openaiChat } from "../_shared/providers/openai.ts";

import { type CoachContext, type CoachListingCtx, buildUserTurn, spaceTypeOf, systemInstruction } from "./prompt.ts";
import { parseCoachOutput } from "./actions.ts";

// ── Tunables ─────────────────────────────────────────────────────────────────

/** 12 messages / 5 min and 60 / day, PER USER — abuse protection on an
 *  always-free feature, not a plan quota (see header, point 2). */
const BURST_MAX_PER_WINDOW = 12;
const BURST_WINDOW_SECONDS = 300;
const DAY_MAX_PER_WINDOW = 60;
const DAY_WINDOW_SECONDS = 86400;

/** Keep the reply short and the bill small — a coaching message, not an essay. */
const MAX_TOKENS = 600;

/** Sliding window: only the most recent turns are sent, oldest dropped first.
 *  Bounds token cost regardless of how long a chat session runs. */
const MAX_HISTORY_MESSAGES = 16;
const MAX_MESSAGE_CHARS = 1200;

const MAX_LISTINGS = 25;
const MAX_TITLE_CHARS = 120;
const KNOWN_PLANS = ["free", "trial", "starter", "solo", "pro", "team"] as const;

// Where the coach was opened from. A CLOSED SET, like KNOWN_PLANS and the
// action enum — not a length-capped free string. `screen` is a hint to the
// model AND it lands in `cost_ledger.meta`, a durable row every member of the
// org can read under the "org ledger" RLS policy; a free string there is a
// 40-character channel from one member into everyone else's billing history,
// which is exactly what the events vocabulary + scrubber exist to prevent for
// analytics. Anything unrecognised becomes null. Add a value here when the app
// adds an entry point (apps/ios/Rendprop/Coach/CoachView.swift call sites).
const KNOWN_SCREENS = ["home", "settings"] as const;

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
    const steps = await resolveRoute("coach.chat", { plan, needs: ["text", "chat"] });
    if (steps.length > 0) return steps; // used AS RETURNED — never re-filtered
  } catch (e) {
    console.error("coach: resolveRoute threw; using the two-step fallback:", e instanceof Error ? e.message : String(e));
  }
  return [ANTHROPIC_FALLBACK, OPENAI_FALLBACK];
}

// ── Body validation — every field is untrusted, nothing is a UUID here ──────
//
// Unlike every other AI route in this codebase, coach never looks anything up
// in the database by id: `context.listings[]` is the CLIENT's own report of
// its own AppModel state (CoachModel.swift), used only to word the reply and
// to validate which `listing_id` an action may name. A stale or wrong id here
// costs nothing but a slightly wrong suggestion — it can never leak another
// org's data, because nothing is ever fetched with it.

interface CoachMessageIn {
  role?: unknown;
  content?: unknown;
}

interface CoachListingIn {
  id?: unknown;
  title?: unknown;
  has_video?: unknown;
  room_tags?: unknown;
  has_tour?: unknown;
  published?: unknown;
  photos?: unknown;
  edits?: unknown;
  reels?: unknown;
}

interface CoachBody {
  messages?: CoachMessageIn[];
  space_type?: unknown;
  context?: {
    listings?: CoachListingIn[];
    plan?: unknown;
    screen?: unknown;
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
    const id = typeof o.id === "string" ? o.id.trim().slice(0, 128) : "";
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      title: typeof o.title === "string" ? o.title.trim().slice(0, MAX_TITLE_CHARS) : "",
      hasVideo: o.has_video === true,
      roomTags: nonNegInt(o.room_tags),
      hasTour: o.has_tour === true,
      published: o.published === true,
      photos: nonNegInt(o.photos),
      edits: nonNegInt(o.edits),
      reels: nonNegInt(o.reels),
    });
  }
  return out;
}

function cleanPlan(raw: unknown): string {
  const s = String(raw ?? "").trim().toLowerCase();
  return (KNOWN_PLANS as readonly string[]).includes(s) ? s : "free";
}

function cleanScreen(raw: unknown): string | null {
  const s = String(raw ?? "").trim().toLowerCase();
  return (KNOWN_SCREENS as readonly string[]).includes(s) ? s : null;
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

    const body = await readJson<CoachBody>(req);
    const messages = cleanMessages(body.messages);
    assert(
      messages.length > 0 && messages[messages.length - 1].role === "user",
      400,
      "messages must be a non-empty array ending in a user message",
    );

    const space = spaceTypeOf(body.space_type);
    const context: CoachContext = {
      listings: cleanListings(body.context?.listings),
      plan: cleanPlan(body.context?.plan),
      screen: cleanScreen(body.context?.screen),
    };
    const validListingIds = new Set(context.listings.map((l) => l.id));

    // Rate limits, PER USER, charged before the provider call (same order as
    // every other durable limiter in this codebase) — see header, point 2.
    if (!(await durableRateLimit(`coachburst:${user.id}`, BURST_MAX_PER_WINDOW, BURST_WINDOW_SECONDS))) {
      throw new HttpError(429, "That's a lot of messages at once — try again in a few minutes.", "rate_limited");
    }
    if (!(await durableRateLimit(`coachday:${user.id}`, DAY_MAX_PER_WINDOW, DAY_WINDOW_SECONDS))) {
      throw new HttpError(429, "You've reached today's message limit for the coach — try again tomorrow.", "rate_limited");
    }

    const system = systemInstruction(space);
    const userTurn = buildUserTurn({ space, context, history: messages });

    const chain = await chooseChain(context.plan);

    const attempt = await runChain("coach.chat", chain, async (step) => {
      if (step.provider === "anthropic") {
        return await anthropicMessages({
          model: step.model,
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
          step.model,
          [{ role: "user", content: [{ type: "input_text", text: `${system}\n\n---\n\n${userTurn}` }] }],
          { maxOutputTokens: MAX_TOKENS, json: true },
        );
      }
      // A future admin-added row this deploy doesn't know how to speak. "other"
      // (not "validation") so runChain() tries the NEXT step instead of
      // hard-failing the whole request over one unrecognised row.
      throw new ProviderError(step.provider, "other", `coach.chat: no adapter for provider "${step.provider}" in this deploy`);
    });

    const output = parseCoachOutput(attempt.value, validListingIds);

    // Ledger — best effort, and never on the critical path: the user is
    // waiting on `output` above, which is already computed. A membership
    // lookup hiccup or a ledger insert failure must never turn a good reply
    // into an error (header, point 2 — this feature has no quota to protect).
    try {
      const orgId = await orgForUser(user.id, preferredOrg(req));
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "coach",
        step: attempt.step,
        meta: {
          message_count: messages.length,
          listing_count: context.listings.length,
          has_action: output.actions.length > 0,
          screen: context.screen,
        },
      });
    } catch (e) {
      console.error("coach: org resolve / ledger write failed (reply already returned):", e instanceof Error ? e.message : String(e));
    }

    return json({
      reply: output.reply,
      actions: output.actions,
      suggested_replies: output.suggested_replies,
      model: attempt.step.model,
    });
  } catch (err) {
    return respondError(err);
  }
});
