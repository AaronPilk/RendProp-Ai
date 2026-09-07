// coach — persona, per-industry vocabulary, the action protocol, and the two
// prompt builders (system + user turn).
//
// PURE (imports only knowledge.ts and actions.ts, both pure), so a test can
// read the exact words sent to the model with no env, no network, no Supabase.
//
// PROJECT-FIRST. Rendprop's whole app is built around ONE idea: nothing gets
// made without a project (a home / venue / restaurant / store / gym) to
// belong to (see RendpropApp.swift's HomeDashboardView header). The coach's
// entire step-picking logic below exists to answer one question in the
// user's own words — "what's the next thing I do?" — using the SAME state
// the app itself already gates on (has a video? has a tour? how many photos,
// edits, reels?).
//
// VOCABULARY mirrors `SpaceType` in apps/ios/Rendprop/Models/Listing.swift
// exactly (spaceNoun, customerNoun, ctaTitle, areaNoun) — a suggestion phrased
// in the model's own invented words ("listing" on a gym, "clients" on a
// restaurant) reads as a bug the first time an agent sees it.

import { ACTION_TYPES } from "./actions.ts";
import { knowledgeBlock } from "./knowledge.ts";

// ── Space-type vocabulary (mirror of Models/Listing.swift SpaceType) ────────

export const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
export type SpaceType = typeof SPACE_TYPES[number];

/** Coerce a client-sent space_type into a known one. Unknown/missing → real_estate,
 *  the same default `SpaceType.current` uses on the client (Listing.swift). */
export function spaceTypeOf(raw: unknown): SpaceType {
  const s = String(raw ?? "").trim().toLowerCase();
  return (SPACE_TYPES as readonly string[]).includes(s) ? (s as SpaceType) : "real_estate";
}

interface SpaceVocab {
  /** "home" | "venue" | "place" | "store" | "studio" | "space" (Listing.spaceNoun). */
  noun: string;
  /** "buyers" | "planners" | "guests" | "shoppers" | "members" | "customers" (Listing.customerNoun). */
  customer: string;
  /** "room" for real estate, "area" for everything else (Listing.areaNoun). */
  area: string;
  /** The primary tour CTA in this industry's words (Listing.ctaTitle) — used so
   *  the coach never says "showing" to a gym or "session" to a house. */
  cta: string;
}

const VOCAB: Record<SpaceType, SpaceVocab> = {
  real_estate: { noun: "home", customer: "buyers", area: "room", cta: "Book a showing" },
  venue: { noun: "venue", customer: "planners", area: "area", cta: "Plan your event" },
  restaurant: { noun: "place", customer: "guests", area: "area", cta: "Book a table" },
  retail: { noun: "store", customer: "shoppers", area: "area", cta: "Visit us" },
  fitness: { noun: "studio", customer: "members", area: "area", cta: "Book a session" },
  other: { noun: "space", customer: "customers", area: "area", cta: "Get in touch" },
};

export function vocabFor(space: SpaceType): SpaceVocab {
  return VOCAB[space];
}

// ── Context (what AppModel already knows, no photo/video ever included) ────

/**
 * One of the user's own projects, as CoachModel.swift builds it from AppModel
 * — never from the server's own listings table (the coach never queries the
 * DB for this; see docs/COACH-CONTRACT.md "no round trip"). All counts, no
 * media: this is the whole reason the feature can be TEXT ONLY.
 */
export interface CoachListingCtx {
  id: string;
  /** The user's own project name/address, e.g. "123 Main St". Plain text the
   *  user chose, not customer media — safe to send and to quote back. */
  title: string;
  hasVideo: boolean;
  /** Count of tagged rooms/areas — never the tag text itself. */
  roomTags: number;
  hasTour: boolean;
  published: boolean;
  photos: number;
  edits: number;
  reels: number;
}

export interface CoachContext {
  listings: CoachListingCtx[];
  /** Client-reported plan name ("free" | "starter" | "solo" | "pro" | "team" |
   *  "trial"). Used only to word plan-aware copy — never to gate anything;
   *  coach is free on every plan by product rule (see 0023's own header). */
  plan: string;
  /** Optional current screen name, e.g. "home" | "settings" | "photo_studio" —
   *  a hint only, never load-bearing. */
  screen: string | null;
}

// ── The action protocol embedded in the prompt ──────────────────────────────

const ACTION_MEANINGS: Record<string, string> = {
  start_project: "begin a brand-new project (the user will name it, then land on adding a walkthrough video). No listing_id.",
  open_tour: "open the tour flow for an EXISTING project — records/uploads the walkthrough, or opens its finished tour. Needs listing_id.",
  open_photos: "open that project's AI Photo Studio (sky, twilight, lawn, tidy, virtual staging). Needs listing_id.",
  open_reel: "open that project's reel maker. Needs listing_id.",
  open_floor_plan: "open that project's floor plan tool (3D scan or upload a plan). Needs listing_id.",
  open_aerial: "open that project's AI aerial intro tool. Needs listing_id.",
  share_tour: "open that project's finished tour, where both the branded and unbranded share links live. Needs listing_id.",
  open_plan_usage: "open the app's Plan & usage screen — the ONLY place that shows the real plan, usage and prices. No listing_id.",
  open_support: "open a way to reach a human at support. No listing_id.",
  open_home: "go back to the Home tab. No listing_id.",
};

function actionsProtocol(): string {
  const lines = ACTION_TYPES.map((t) => `  - "${t}": ${ACTION_MEANINGS[t]}`);
  return [
    "Respond with ONLY one JSON object — no prose before or after it, no markdown fence — matching exactly:",
    '{"reply": string, "actions": [{"type": string, "label": string, "listing_id"?: string}], "suggested_replies": [string]}',
    "",
    `"actions" holds AT MOST ONE entry — you present exactly one primary next step, never a menu. Empty array when there is no natural next step (e.g. answering a pure support question).`,
    `"type" MUST be exactly one of these ${ACTION_TYPES.length} values — never invent a new one:`,
    ...lines,
    "",
    `A listing action's "listing_id" MUST be copied EXACTLY from one of the project ids given to you below — never invented, never guessed, never a title or address. If you are not sure which project the user means and more than one could fit, ask ONE short question instead of emitting an action.`,
    '"label" is the button text the user taps — five words or fewer, a verb phrase ("Add the walkthrough", "Open Photo Studio"), never the action\'s raw type.',
    '"suggested_replies" holds 0 to 4 short reply chips (a few words each) the user might tap instead of typing — natural next things THEY would say, not more assistant text.',
  ].join("\n");
}

// ── System instruction ──────────────────────────────────────────────────────

export function systemInstruction(space: SpaceType): string {
  const v = vocabFor(space);
  return [
    "You are Coach, the assistant built into the Rendprop iPhone app. Rendprop turns a phone " +
      "walkthrough into a shareable, drone-style property tour. You have two jobs, and you " +
      "always know which one you're doing from what the user just said:",
    "",
    "JOB 1 — ONBOARDING. Guide the user through their first (or next) project, one step at a " +
      "time. Never dump the whole plan on them. Give exactly ONE next step and exactly ONE " +
      "action to take it. If you are missing something you genuinely need (which project, or " +
      "which tool) ask exactly ONE short question — never more than one at a time, and never " +
      "ask something the project list below already answers.",
    "",
    "The step ladder, in order — pick the FIRST one that applies to what the user is asking " +
      "about right now:",
    "  1. No project matches what they described exists yet → action start_project.",
    "  2. Their project has no video yet (has_video is false) → action open_tour (this is where " +
      "recording or uploading the walkthrough happens — nothing else can start before it).",
    "  3. It has a video but no finished tour yet (has_tour is false) → action open_tour (this " +
      "finishes building the tour).",
    "  4. They asked about photos/staging and photos is 0 → action open_photos.",
    "  5. They asked for a reel and reels is 0 → action open_reel.",
    "  6. They asked for a floor plan → action open_floor_plan.",
    "  7. They asked for an aerial shot → action open_aerial.",
    "  8. Everything they asked for already exists → congratulate them briefly and offer " +
      "share_tour (to get the link) or open_home — never propose redoing a finished step.",
    "",
    "JOB 2 — CUSTOMER SERVICE, and it is the higher priority of the two. Answer questions about " +
      "publishing, the unbranded MLS link, how AI content is disclosed, what each tool does, " +
      "filming tips, deleting an account, and managing a subscription, using ONLY the knowledge " +
      "given to you below. This job must never fail: if a question is outside that knowledge, " +
      "say so plainly and offer action open_support — never guess, and never invent a feature, " +
      "a screen, a policy or a number that isn't in the knowledge.",
    "",
    "HARD RULES, always:",
    `  • Business type right now: ${v.noun} (industry: ${space}). Call one project "a ${v.noun}", ` +
      `its customers "${v.customer}", a tagged section "a ${v.area}", and its main tour action ` +
      `"${v.cta}" — never a different industry's words.`,
    "  • NEVER state a price. Prices exist only in the App Store via StoreKit and can change or " +
      "differ by region — say what a plan INCLUDES (from the knowledge below) and use action " +
      "open_plan_usage for the current plan, usage or the real price.",
    "  • NEVER write marketing copy, a listing description, or ad text for the user's project — " +
      "that runs through Rendprop's own fair-housing-checked tools (AI Photo Studio, Reels), " +
      "never through this chat. Point to the right tool with an action instead of writing it " +
      "yourself.",
    "  • NEVER claim a feature, screen or setting that isn't in the knowledge below or in the " +
      "project data you're given. If you don't know, say so and offer open_support.",
    "  • This chat is TEXT ONLY — no photo or video is ever part of it, and you never ask for one.",
    "  • Warm and plain, never salesy or robotic. One idea per reply. 80 words or fewer.",
    "",
    "KNOWLEDGE BASE (the only facts you may state as customer-service answers):",
    knowledgeBlock(),
    "",
    actionsProtocol(),
  ].join("\n");
}

// ── User turn: the live project state + the conversation so far ────────────

export interface UserTurnArgs {
  space: SpaceType;
  context: CoachContext;
  /** Trimmed, validated, oldest-first. The LAST entry is the user's newest message. */
  history: Array<{ role: "user" | "assistant"; content: string }>;
}

function describeListing(l: CoachListingCtx, space: SpaceType): string {
  const v = vocabFor(space);
  const bits = [
    `id=${l.id}`,
    `title="${l.title || "(untitled)"}"`,
    `has_video=${l.hasVideo}`,
    `${v.area}_tags=${l.roomTags}`,
    `has_tour=${l.hasTour}`,
    `published=${l.published}`,
    `photos=${l.photos}`,
    `photo_edits=${l.edits}`,
    `reels=${l.reels}`,
  ];
  return `  - ${bits.join(", ")}`;
}

/**
 * The USER turn sent to the model: the live project list (so step-picking is
 * grounded in real state, never guessed) plus the conversation transcript.
 * `history` already has the system's rules; this only needs to be the facts
 * and the words actually exchanged.
 */
export function buildUserTurn(args: UserTurnArgs): string {
  const { space, context, history } = args;
  const listingLines = context.listings.length > 0
    ? context.listings.map((l) => describeListing(l, space)).join("\n")
    : "  (none yet — this user has no projects at all)";

  const transcript = history
    .map((m) => `${m.role === "user" ? "User" : "Coach"}: ${m.content}`)
    .join("\n");

  return [
    `The user's current plan: ${context.plan}.` +
      (context.screen ? ` They are currently on the "${context.screen}" screen.` : ""),
    "Their projects right now (this is the ONLY source of listing ids you may use):",
    listingLines,
    "",
    "Conversation so far (oldest first; respond to the last User line):",
    transcript,
    "",
    "Reply now with the one JSON object described in your instructions. Nothing else.",
  ].join("\n");
}
