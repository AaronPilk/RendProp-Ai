// ai-copy — AI PROMPTING FOR PEOPLE WHO ARE NOT PROMPT ENGINEERS.
// Owner-authenticated. Three routes on one function, the way ai-voice serves
// /voices and /tts.
//
//   POST /ai-copy/script        task `copy.reel_script`
//     { listing_id?, space_type, facts{beds,baths,sqft,price_label,tagline,
//       region,details}, room_tags?[], photo_count, target_seconds, tone? }
//       -> { script, characters, estimated_seconds, model }
//
//   POST /ai-copy/shotlist      task `copy.shotlist`
//     { listing_id?, space_type, facts{…}, photos[{id,room?,caption_hint?}],
//       target_seconds?, tone? }
//       -> { shots[{photo_id,order,motion,room,on_screen_text,seconds,
//            voice_line}], script, characters, estimated_seconds, model }
//
//   POST /ai-copy/edit-prompt   task `copy.photo_prompt`
//     { listing_id?, space_type, rough (<=300), room_hint? }
//       -> { prompt, model }
//
// ── WHY /shotlist IS ONE CALL AND NOT THREE ─────────────────────────────────
//
// A reel today is: tap N photos → each becomes a five-second clip under ONE
// fixed server prompt ("one slow, subtle, grounded push-in", ai-video
// `reelPrompt()`) → stitch in tap order → lay a separately-written voiceover
// over the top. Every clip moves identically, the order is whatever order a
// thumb moved in, and the script was written without knowing what is on screen
// when it plays. /shotlist decides the order, the camera move, the hold, the
// burned-in caption and the narration TOGETHER, because they are one decision:
// the line for shot 3 can only describe shot 3 if whoever writes it knows what
// shot 3 is. The SERVER owns the structure (deterministic, renderable) and the
// MODEL owns the words — see ai-copy/shotlist.ts for the whole argument.
//
// Full contract (JSON, the character budget, what the client must do with
// {address}): docs/COPY-ASSIST-CONTRACT.md
//
// ── WHY ──────────────────────────────────────────────────────────────────────
//
// The app's owner, a performance marketer, asked for "AI prompting installed
// for like describing how to change an image, describing a script for the reel
// so that way prompting is perfect." Both halves are the same complaint: the
// product hands a blank text field to somebody whose job is marketing, not
// prompt engineering, and then quietly gives them a worse result than the
// person who tapped a preset button.
//
// The asymmetry is measurable in ai-photo/index.ts today. A PRESET edit is
// built from ~60 words of engineered direction (RE_PROMPTS + STAGE_LOCK +
// RE_STAGE_STYLES) naming what changes, what stays identical, and how the light
// and materials must behave. A CUSTOM edit is `customPrompt()`: one sentence
// wrapped around whatever the user typed, so the user's raw words carry the
// whole semantic load. /ai-copy/edit-prompt closes that gap, and SUPERSEDES
// ai-photo's `edit:"improve_prompt"` — which still works, unchanged from the
// client's point of view (shipped builds call it), but now builds its request
// from the same shared instruction so there is ONE polisher instead of two that
// drift. See ai-copy/prompt.ts `editPromptInstruction()`.
//
// ── THE PRIVACY LINE: THE STREET ADDRESS IS NEVER SENT HERE ─────────────────
//
// There is no address field in either body and there never will be. This is the
// same line ai-video's aerial route already holds: it accepts `region`
// ("Sausalito, CA"), `cleanRegion()` drops anything that starts like a house
// number, and its `address` field is documented as accepted-and-ignored.
//
// So the model is told to write the literal token `{address}` wherever the
// property should be named, and THE CLIENT SUBSTITUTES IT ON-DEVICE, where the
// address already lives. The property gets named in the finished voiceover and
// no vendor ever receives the address of somebody's home. prompt.ts also
// scrubs anything street-address-shaped out of the model's answer — the request
// contains nothing to copy an address from, so any address in the output is
// invented, and an invented house number in a voiceover is worse than none.
//
// ── LENGTH IS A HARD CONSTRAINT ─────────────────────────────────────────────
//
// The reel stitcher lets VIDEO LENGTH WIN: a voiceover longer than the stitched
// clips does not truncate, it HOLDS THE LAST VIDEO FRAME while the voice keeps
// talking (FlythroughDetailView.swift `stitch(clips:renderSize:…)`). So a long
// script is not "a bit long", it is a reel that ends on a frozen still.
//
// The budget is ~11 characters per second of video, from ai-voice's own
// committed number (1,000 chars ≈ 90 s ⇒ 11.1 ch/s, rounded DOWN because short
// is free and long freezes a frame), clamped to MAX_SCRIPT_CHARS = 1000 to
// match ai-voice/index.ts MAX_TEXT_CHARS exactly. `characters` and
// `estimated_seconds` come back so the client can show the fit. See
// ai-copy/prompt.ts for the arithmetic and prompt_test.ts for the assertions.
//
// ── GATES (every route, fail closed) ───────────────────────────────────────
//
//  1. AUTH + ORG + ROLE. Owner JWT; `marketing` is read-only, the same gate
//     ai-photo and ai-voice apply.
//  2. FAIR HOUSING ON THE INPUT, BEFORE A TOKEN IS SPENT (ai-photo's
//     improve_prompt does this and says why: polishing a phrase we would never
//     run costs money to produce copy we then refuse anyway).
//  3. FAIR HOUSING ON THE OUTPUT. Model-authored text is re-checked and, if it
//     trips, RETRIED ONCE and then refused honestly — never handed to the user
//     as their error. This is ai-chapters principle 3, adapted: ai-chapters
//     DROPS an offending chapter description and keeps the chapter, because a
//     chapter survives without one; a script has no sub-part to drop. The whole
//     ordering lives in ai-copy/guard.ts so it is testable.
//  4. THE SPACE TYPE COMES FROM THE LISTING when `listing_id` is present, not
//     from the body (ai-photo/index.ts `gateSpace()`): the request must not be
//     able to loosen its own gate by claiming to be a bar.
//  5. ORG BURST LIMITER, 60 / 5 min. NO monthly meter and NO plan_entitlements
//     migration — this is ai-photo's helper-mode shape (`guardHelper`,
//     aiphotohelp:<org>, 120/5min, no monthly meter), which is the right shape
//     for a sub-2¢ call that generates no image and no video.
//
// ── COST VISIBILITY (this is new) ───────────────────────────────────────────
//
// Every success writes ONE org-scoped cost_ledger row via recordRoutedAiCost()
// with feature "copy_assist" and the provider/model that ACTUALLY ran. Note
// what that changes: ai-photo's existing helper modes (`suggest`,
// `improve_prompt`) write NO ledger row at all today, so their spend — small
// per call, unbounded per month — is invisible to GET /admin/spend and to the
// per-org COGS ceiling. This function is the first assist route that is
// visible. (The bigger hole in the same class was ai-voice, which billed 22¢
// per 1k characters with no ledger row; it is routed and metered in this same
// wave — see ai-voice/index.ts.)
//
// ── THE ROUTER, WITH THE FLAG OFF ───────────────────────────────────────────
//
// `copy.reel_script`, `copy.photo_prompt` and `copy.shotlist` are BRAND NEW
// tasks: like coach.chat and unlike photo.*/video.*, they have no shipped
// hardcoded behaviour to preserve, so migrations 0027 and 0028 seed NO
// `note='legacy'` row for any of them. With
// the flag off (today's default) resolveRoute() finds no legacy row and answers
// `[]`. Rather than collapse to a single hardcoded step — which would leave a
// brand-new feature with no cross-provider failover precisely while the master
// flag is off, i.e. all the time — `chooseChain()` below substitutes its own
// in-code chain, byte-identical to the rows 0027 and 0028 seed. This is copied from
// coach/index.ts, deliberately and for the same reason.
//
// Needs ANTHROPIC_API_KEY and OPENAI_API_KEY (both already set); GEMINI_API_KEY
// only if an operator enables the seeded gemini step.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, listingSpaceType, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { entitlementFor } from "../_shared/entitlements.ts";
import { recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { resolveRoute } from "../_shared/router.ts";
import { runChain } from "../_shared/providers/chain.ts";
import { ProviderError, fetchJson, BUDGETS, snippet } from "../_shared/providers/common.ts";
import { anthropicMessages } from "../_shared/providers/anthropic.ts";
import { openaiChat } from "../_shared/providers/openai.ts";

import {
  type ScriptFacts,
  MAX_PROMPT_INPUT,
  MAX_PROMPT_OUTPUT,
  buildScriptTurn,
  charBudgetFor,
  cleanEditPrompt,
  cleanFacts,
  cleanRoomTags,
  cleanScript,
  cleanTargetSeconds,
  editPromptInstruction,
  estimatedSecondsFor,
  extractJsonObject,
  scriptInstruction,
  spaceTypeOf,
  toneOf,
  userFreeText,
} from "./prompt.ts";
import {
  MAX_SHOTS,
  type ShotlistAnswer,
  type ShotlistRequest,
  buildShotlistTurn,
  cleanPhotos,
  cleanShotlistTarget,
  parseShotlist,
  photoWords,
  planCharBudget,
  planSeconds,
  planShots,
  shotlistInstruction,
} from "./shotlist.ts";
import { EMPTY_REFUSAL, assertInputSafe, guardedCopy } from "./guard.ts";

// ── Tunables ─────────────────────────────────────────────────────────────────

/** 60 assists / 5 min / org. Same shape as ai-photo's helper limiter
 *  (aiphotohelp:<org>, 120/5min): a burst guard on a cheap text call, NOT a
 *  paid allowance — so it is never refunded and never metered monthly. */
const BURST_MAX_PER_WINDOW = 60;
const BURST_WINDOW_SECONDS = 300;

/** Bound the reply. A reel script is ~1,000 characters at the very most and a
 *  polished photo prompt is 400, so this is generous by design — it exists to
 *  stop a runaway generation, not to shape the answer. */
const MAX_TOKENS = 700;

/** Bound the /shotlist reply, which is one caption plus one line per shot
 *  rather than one paragraph. Twenty shots at roughly fifty-five tokens of JSON
 *  each is ~1,100; the rest is slack, for the same reason MAX_TOKENS is
 *  generous — it stops a runaway generation, it does not shape the answer. */
const MAX_SHOTLIST_TOKENS = 1600;

/** Reel photo count. 5 s per clip and the app's own reel ceiling put this well
 *  under 20; the cap only exists so a junk body cannot reach the prompt. */
const MAX_PHOTO_COUNT = 60;

// ── The in-code chain (see the header). MUST match the rows seeded by
// 0027_copy_routes.sql and 0028_shotlist_route.sql exactly, so the flag-off path
// and the flag-on path route and price identically. All three tasks are the same
// shape as text.listing_copy — one bounded text answer, no image in, no image
// out — so they reuse its three vetted providers/models/prices verbatim rather
// than inventing new ones. ──

function fallbackStep(task: string, position: 1 | 2): RouteStep {
  const anthropic = position === 1;
  return {
    route_id: `${task.replace(/\./g, "-")}-fallback-${anthropic ? "anthropic" : "openai"}`,
    task,
    provider: anthropic ? "anthropic" : "openai",
    model: anthropic ? "claude-sonnet-5" : "gpt-5.6-terra",
    unit: "call",
    unit_cents: anthropic ? 2.1 : 2.0,
    capabilities: ["text", "compliant"],
    max_latency_s: 60,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
  };
}

/**
 * Today's chain for `task`.
 *
 * `resolveRoute` is designed to fail toward its own legacy step and never throw
 * for a routing reason (router.ts), so the try/catch is belt-and-braces. An
 * empty answer — which is what the flag-off path returns for a task with no
 * `note='legacy'` row — gets the two-step in-code chain instead of one step, so
 * a single vendor outage cannot take a brand-new feature down.
 *
 * The result is used AS RETURNED and never re-filtered (contract rule 2).
 */
async function chooseChain(task: string, plan: string): Promise<RouteStep[]> {
  try {
    const steps = await resolveRoute(task, { plan, needs: ["text", "compliant"] });
    if (steps.length > 0) return steps;
  } catch (e) {
    console.error(
      `ai-copy: resolveRoute(${task}) threw; using the two-step fallback:`,
      e instanceof Error ? e.message : String(e),
    );
  }
  return [fallbackStep(task, 1), fallbackStep(task, 2)];
}

/**
 * The org's plan, for the router's RouteContext ONLY — never for access.
 *
 * Copy assist is free on every plan by product decision (see the header, gate
 * 5), so this uses `entitlementFor()`, which degrades to `trial` and NEVER
 * throws, rather than `entitlementForCharge()`, whose whole job is to turn a
 * degraded lookup into a 503 before a charge. There is no charge here to
 * protect, and a plan-table blip must not take a 2¢ text call down. The plan
 * only decides POLICY (starter routes cheapest, pro routes best); every seeded
 * step is `min_plan='free'`, so it can never decide access.
 */
async function routingPlan(orgId: string): Promise<string> {
  try {
    return (await entitlementFor(orgId)).plan;
  } catch (e) {
    console.error("ai-copy: plan lookup failed; routing as free:", e instanceof Error ? e.message : String(e));
    return "free"; // the most restrictive rank — never hands out a premium step
  }
}

// ── Auth / org / burst ───────────────────────────────────────────────────────

/** Role gate + burst limiter. Mirrors ai-photo's `guardHelper()`: a role check
 *  and ONE burst key, no monthly meter, nothing refundable. */
async function guardAssist(userId: string, req: Request): Promise<string> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const { data: mem, error: mErr } = await adminClient()
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI writing help");
  }
  if (!(await durableRateLimit(`aicopy:${orgId}`, BURST_MAX_PER_WINDOW, BURST_WINDOW_SECONDS))) {
    throw new HttpError(429, "Too many writing requests for now — try again in a few minutes.", "rate_limited");
  }
  return orgId;
}

// ── Providers ────────────────────────────────────────────────────────────────

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

/**
 * One text-only generateContent call, for the seeded gemini step.
 *
 * _shared/providers/gemini.ts is an IMAGE adapter (its submit() refuses without
 * `image_b64`), and ai-photo carries its own local `geminiText()` for exactly
 * this reason. This is the second copy of that shape, and both belong in
 * _shared/providers/gemini.ts as `geminiText()` the moment that file is open
 * for edits — the same scoping duplicate ai-chapters and ai-voice made with
 * `presignGet`, not a second way of doing things.
 */
async function geminiText(model: string, system: string, turn: string, maxTokens: number): Promise<string> {
  const key = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!key) throw new ProviderError("gemini", "upstream", "GEMINI_API_KEY function secret is not set");
  const data = await fetchJson<Record<string, unknown>>(
    "gemini",
    `${GEMINI_BASE}/${encodeURIComponent(model)}:generateContent`,
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: `${system}\n\n---\n\n${turn}` }] }],
        generationConfig: {
          temperature: 0.7,
          responseMimeType: "application/json",
          maxOutputTokens: maxTokens,
        },
      }),
    },
    BUDGETS.submitMs,
  );
  // deno-lint-ignore no-explicit-any
  for (const cand of (((data as any).candidates ?? []) as Array<Record<string, unknown>>)) {
    // deno-lint-ignore no-explicit-any
    for (const part of ((((cand as any).content?.parts) ?? []) as Array<Record<string, unknown>>)) {
      if (typeof part.text === "string" && part.text.trim()) return part.text;
    }
  }
  throw new ProviderError("gemini", "upstream", `Gemini returned no text: ${snippet(data, 200)}`);
}

/** Run ONE step of the chain. An unknown provider is error_class "other" (not
 *  "validation") so runChain() tries the NEXT step rather than hard-failing the
 *  whole request over one admin-added row this deploy cannot speak. */
async function callStep(
  step: RouteStep,
  system: string,
  turn: string,
  maxTokens: number = MAX_TOKENS,
): Promise<string> {
  if (step.provider === "anthropic") {
    return await anthropicMessages({
      model: step.model,
      system,
      content: [{ type: "text", text: turn }],
      maxTokens,
    });
  }
  if (step.provider === "openai") {
    // One user-role message carrying both the system rules and the turn — the
    // shape openaiJudge() and coach/index.ts already use. `json: true` asks the
    // Responses API for a syntactically valid object; extractJsonObject() still
    // re-validates, because "valid JSON" is not "safe to publish".
    return await openaiChat(
      step.model,
      [{ role: "user", content: [{ type: "input_text", text: `${system}\n\n---\n\n${turn}` }] }],
      { maxOutputTokens: maxTokens, json: true },
    );
  }
  if (step.provider === "gemini") return await geminiText(step.model, system, turn, maxTokens);
  throw new ProviderError(
    step.provider,
    "other",
    `${step.task}: no adapter for provider "${step.provider}" in this deploy`,
  );
}

/** The corrective line added to the SECOND attempt. It never quotes what the
 *  model wrote (guard.ts keeps that out of everything) — it restates the rule,
 *  which is the only actionable thing we know. */
const RETRY_NOTE =
  "\n\nYour previous answer was rejected by the fair-housing check. Rewrite it describing ONLY the " +
  "property and what is in it. Say nothing about people, families, children, occupants, " +
  "neighbours, a neighbourhood, schools, religion, or who would like it here.";

// ── Bodies ───────────────────────────────────────────────────────────────────

interface ScriptBody {
  listing_id?: string;
  space_type?: string;
  facts?: unknown;
  room_tags?: unknown;
  photo_count?: unknown;
  target_seconds?: unknown;
  tone?: unknown;
}

interface ShotlistBody {
  listing_id?: string;
  space_type?: string;
  facts?: unknown;
  photos?: unknown;
  target_seconds?: unknown;
  tone?: unknown;
}

interface EditPromptBody {
  listing_id?: string;
  space_type?: string;
  rough?: unknown;
  room_hint?: unknown;
}

// ── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req); // owner auth
    const seg = pathSegments(req, "ai-copy");
    const route = seg.length === 1 ? seg[0] : "";

    if (req.method !== "POST" || (route !== "script" && route !== "shotlist" && route !== "edit-prompt")) {
      throw new HttpError(
        404,
        "Unknown ai-copy route — use POST /ai-copy/script, POST /ai-copy/shotlist or POST /ai-copy/edit-prompt",
        "not_found",
      );
    }

    // ---- POST /ai-copy/script ----
    if (route === "script") {
      const body = await readJson<ScriptBody>(req);

      // VALIDATE FIRST, CHARGE SECOND (audit round 4): everything below the
      // guard is known-good before a limiter token is taken.
      const facts: ScriptFacts = cleanFacts(body.facts);
      const roomTags = cleanRoomTags(body.room_tags);
      const targetSeconds = cleanTargetSeconds(body.target_seconds);
      const charBudget = charBudgetFor(targetSeconds);
      const photoCount = Math.min(
        MAX_PHOTO_COUNT,
        Math.max(0, Math.round(Number(body.photo_count)) || 0),
      );
      const tone = toneOf(body.tone);

      // The LISTING wins over the body (gate 4). listingSpaceType() never
      // throws and answers null for a row the caller cannot see — and null is
      // the STRICTER housing gate, so an unreadable listing fails closed.
      const listingSpace = await listingSpaceType(userClient(req), body.listing_id);
      const space = spaceTypeOf(listingSpace ?? body.space_type);

      // FAIR HOUSING ON THE INPUT, ahead of everything else — the same place in
      // the sequence ai-photo's improve_prompt puts it, and for the reason it
      // gives there: refuse before spending tokens producing copy we would only
      // have to refuse anyway. `guardedCopy()` runs this same gate again as the
      // one place the whole ordering is enforced (and tested); the pure regex
      // pass over a few hundred characters is free, and having it in two
      // independent places is the point.
      const brief = userFreeText(facts, roomTags);
      assertInputSafe("marketing", brief, "This reel brief", listingSpace);

      const orgId = await guardAssist(user.id, req);
      const plan = await routingPlan(orgId);
      const task = "copy.reel_script";
      const chain = await chooseChain(task, plan);

      const request = { space, tone, targetSeconds, charBudget, facts, roomTags, photoCount };
      const system = scriptInstruction(request);
      const turn = buildScriptTurn(request);

      // One `attempt` closure per generation, so the retry runs the WHOLE chain
      // again rather than pinning the second try to the step that just failed
      // the compliance check — a different provider is a genuinely different
      // answer, which is the point of retrying at all.
      let lastStep: RouteStep = chain[0];
      const written = await guardedCopy({
        gate: "marketing",
        input: brief,
        inputWhat: "This reel brief",
        outputWhat: "This script",
        spaceType: listingSpace,
        // An object that parsed is trusted ONLY for its `script` field: falling
        // back to the raw text there would flatten `{"script":["a","b"]}` into
        // a "script" that reads out loud as JSON. No object at all means the
        // model answered in prose, which is worth keeping rather than throwing
        // away a generation we have already paid for.
        clean: (raw) => {
          const obj = extractJsonObject(raw);
          if (obj) return typeof obj.script === "string" ? cleanScript(obj.script, charBudget) : "";
          return cleanScript(raw, charBudget);
        },
        refusal:
          "We couldn't write a script for this one that clears the fair-housing rules — " +
          "nothing was returned. Try again, or add a line about what to emphasise " +
          "(the space itself, not who it's for).",
        attempt: async (isRetry) => {
          const attempt = await runChain(task, chain, (step) =>
            callStep(step, system, isRetry ? turn + RETRY_NOTE : turn));
          lastStep = attempt.step;
          return attempt.value;
        },
      });

      // LEDGER — the assist succeeded and is billed, so record ONE org-scoped
      // row with the provider/model that actually ran. Best effort and off the
      // critical path: recordRoutedAiCost never throws (see _shared/ledger.ts),
      // and the script above is already written. `meta` lands in cost_ledger.meta,
      // a durable row every member of the org can read under the org-ledger RLS
      // policy, so it carries only a closed-vocabulary `kind` and a bounded
      // integer — never the brief, never the script (coach/index.ts makes the
      // same argument about `screen`).
      //
      // KNOWN, DELIBERATE UNDER-REPORT: a compliance retry runs the chain a
      // second time and therefore costs two calls, but `unitsForStep()` returns
      // a hardcoded 1 for unit "call" (_shared/ledger.ts), so the row prices
      // ONE. `meta.attempts` carries the truth so the gap is auditable rather
      // than invisible. Faking it with `unitCentsOverride` would put 4.2 in
      // `unit_cost_cents`, a column the admin provider inventory reads as a
      // PRICE — a wrong price is a worse lie than a known 2¢ under-count on a
      // path that should be rare. Fix it properly by teaching unitsForStep()
      // about calls when _shared/ledger.ts is next open for edits.
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "copy_assist",
        step: lastStep,
        meta: { kind: "reel_script", target_seconds: targetSeconds, attempts: written.attempts },
      });

      const script = written.text;
      return json({
        script,
        characters: script.length,
        estimated_seconds: estimatedSecondsFor(script.length),
        model: lastStep.model,
      });
    }

    // ---- POST /ai-copy/shotlist ----
    if (route === "shotlist") {
      const body = await readJson<ShotlistBody>(req);

      // VALIDATE FIRST, CHARGE SECOND (audit round 4), exactly as /script does.
      const facts: ScriptFacts = cleanFacts(body.facts);
      const tone = toneOf(body.tone);

      // The RAW count is checked before anything is cleaned, so a request with
      // thirty photos is refused for the reason it is actually wrong — not
      // quietly reduced to twenty by a dedupe. Refusing beats truncating: the
      // user picked those photos, and a reel silently missing ten of them is a
      // worse answer than a sentence telling them the limit.
      const rawPhotos = Array.isArray(body.photos) ? body.photos : [];
      assert(
        rawPhotos.length > 0,
        400,
        "`photos` is required — send the photos the user picked, in the order they picked them",
      );
      assert(
        rawPhotos.length <= MAX_SHOTS,
        400,
        `A reel is at most ${MAX_SHOTS} shots — you sent ${rawPhotos.length}. Pick fewer photos.`,
      );
      const photos = cleanPhotos(rawPhotos);
      assert(photos.length > 0, 400, "every photo needs its own non-empty `id`");

      // THE PLAN IS PURE AND RUNS BEFORE ANYTHING IS SPENT: the order, the
      // camera moves and the per-shot seconds are decided here, deterministically
      // (ai-copy/shotlist.ts). A length no whole number of 2-12 s clips can hit
      // is CLAMPED here rather than discovered by the provider after the user
      // has already paid for the words, and `targetSeconds` below is therefore
      // the reel's REAL length, not the one that was asked for.
      const plan = planShots(photos, cleanShotlistTarget(body.target_seconds, photos.length));
      const targetSeconds = planSeconds(plan);
      const charBudget = planCharBudget(plan);

      // The LISTING wins over the body (gate 4), same as /script.
      const listingSpace = await listingSpaceType(userClient(req), body.listing_id);
      const space = spaceTypeOf(listingSpace ?? body.space_type);

      // FAIR HOUSING ON THE INPUT, ahead of everything else. The room labels and
      // the photographer's notes are the CALLER's own words and they go straight
      // into the prompt, so they are gated with the facts — `photoWords()` is
      // what makes them part of the brief the gate reads.
      const brief = userFreeText(facts, photoWords(photos));
      assertInputSafe("marketing", brief, "This reel brief", listingSpace);

      const orgId = await guardAssist(user.id, req);
      const orgPlan = await routingPlan(orgId);
      const task = "copy.shotlist";
      const chain = await chooseChain(task, orgPlan);

      const request: ShotlistRequest = { space, tone, facts, plan, charBudget, targetSeconds };
      const system = shotlistInstruction(request);
      const turn = buildShotlistTurn(request);

      // THE OUTPUT GATE HAS TO READ MORE THAN THE SCRIPT HERE. `guardedCopy()`
      // gates ONE string, and this route publishes two kinds of model-authored
      // copy: the narration AND every caption burned into a clip. So `clean()`
      // returns the COMPLIANCE SURFACE — the script joined with every
      // on_screen_text (shotlist.ts `SURFACE_SEPARATOR` explains why the join
      // cannot manufacture or hide a phrase) — and collects the structured
      // answer that produced it. Nothing is weakened: a caption that trips the
      // rules costs the whole attempt, gets the one retry, and is then refused
      // honestly, exactly as a bad script is.
      let lastStep: RouteStep = chain[0];
      const parsed: ShotlistAnswer[] = [];
      const written = await guardedCopy({
        gate: "marketing",
        input: brief,
        inputWhat: "This reel brief",
        outputWhat: "This reel",
        spaceType: listingSpace,
        clean: (raw) => {
          const answer = parseShotlist(raw, plan);
          if (!answer) return ""; // no narration at all: a broken answer, not a refusal
          parsed.push(answer);
          return answer.surface;
        },
        refusal:
          "We couldn't write this reel in a way that clears the fair-housing rules — " +
          "nothing was returned. Try again, or add a line about what to emphasise " +
          "(the space itself, not who it's for).",
        attempt: async (isRetry) => {
          const attempt = await runChain(task, chain, (step) =>
            callStep(step, system, isRetry ? turn + RETRY_NOTE : turn, MAX_SHOTLIST_TOKENS));
          lastStep = attempt.step;
          return attempt.value;
        },
      });

      // Look the answer up BY THE SURFACE THAT PASSED THE GATE rather than
      // assuming the last one parsed is the accepted one. It always is — the
      // loop returns the moment a surface clears — but the shots we hand back
      // must provably be the shots that were checked, not the shots from an
      // attempt that was thrown away.
      const answer = parsed.find((a) => a.surface === written.text);
      if (!answer) throw new HttpError(502, EMPTY_REFUSAL, "upstream");

      // Same ledger note as /script (units 1, `attempts` in meta). `shots` is a
      // bounded integer, which is the only kind of thing that belongs in a
      // durable row every member of the org can read — never a room label,
      // never a caption, never the script.
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "copy_assist",
        step: lastStep,
        meta: {
          kind: "shotlist",
          target_seconds: targetSeconds,
          attempts: written.attempts,
          shots: answer.shots.length,
        },
      });

      // `characters` / `estimated_seconds` mean exactly what they mean on
      // /script: the length of the SPOKEN script and how long it takes to say.
      // The reel's own length is the sum of shots[].seconds and equals
      // `targetSeconds` — the client shows one against the other, and a script
      // that estimates longer than the video is the frozen last frame again.
      return json({
        shots: answer.shots,
        script: answer.script,
        characters: answer.script.length,
        estimated_seconds: estimatedSecondsFor(answer.script.length),
        model: lastStep.model,
      });
    }

    // ---- POST /ai-copy/edit-prompt ----
    const body = await readJson<EditPromptBody>(req);
    const rough = String(body.rough ?? "").replace(/\s+/g, " ").trim();
    assert(rough.length > 0, 400, "`rough` is required — describe the change in your own words");
    assert(rough.length <= MAX_PROMPT_INPUT, 400, `rough is too long (max ${MAX_PROMPT_INPUT} chars)`);
    const roomHint = String(body.room_hint ?? "").replace(/\s+/g, " ").trim().slice(0, 60);

    const listingSpace = await listingSpaceType(userClient(req), body.listing_id);
    const space = spaceTypeOf(listingSpace ?? body.space_type);

    // Same ordering as the script route: refuse before anything is spent. This
    // is byte-for-byte the gate ai-photo's improve_prompt applies to this exact
    // text, in the same position in the sequence.
    assertInputSafe("image_prompt", rough, "That idea", listingSpace);

    const orgId = await guardAssist(user.id, req);
    const plan = await routingPlan(orgId);
    const task = "copy.photo_prompt";
    const chain = await chooseChain(task, plan);

    const system = editPromptInstruction(space, roomHint);
    const turn = `The user's idea: ${rough}`;

    let lastStep: RouteStep = chain[0];
    const polished = await guardedCopy({
      // An image-edit idea, so it gets ai-photo's own gate for this exact text
      // (the denylist with its ADD-verb tier), not the script rules.
      gate: "image_prompt",
      input: rough,
      inputWhat: "That idea",
      outputWhat: "That edit",
      spaceType: listingSpace,
      // Same rule as the script route: trust the object's own field, or the
      // prose if there was no object at all — never the raw JSON in between.
      clean: (raw) => {
        const obj = extractJsonObject(raw);
        if (obj) return typeof obj.prompt === "string" ? cleanEditPrompt(obj.prompt, MAX_PROMPT_OUTPUT) : "";
        return cleanEditPrompt(raw, MAX_PROMPT_OUTPUT);
      },
      refusal:
        "We couldn't turn that into an edit instruction we're allowed to run — nothing was " +
        "returned. Try describing the change to the space itself.",
      attempt: async (isRetry) => {
        const attempt = await runChain(task, chain, (step) =>
          callStep(step, system, isRetry ? turn + RETRY_NOTE : turn));
        lastStep = attempt.step;
        return attempt.value;
      },
    });

    // Same ledger note as the script route above (units 1, `attempts` in meta).
    await recordRoutedAiCost(adminClient(), {
      orgId,
      feature: "copy_assist",
      step: lastStep,
      meta: { kind: "photo_prompt", target_seconds: null, attempts: polished.attempts },
    });

    return json({ prompt: polished.text, model: lastStep.model });
  } catch (err) {
    return respondError(err);
  }
});
