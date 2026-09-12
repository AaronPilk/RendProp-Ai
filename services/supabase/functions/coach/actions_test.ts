// coach — action-parser tests.
//
//   deno test services/supabase/functions/coach/actions_test.ts
//
// Pure — no env, no network, no Supabase. Covers the two things that make the
// closed action enum actually closed: an out-of-enum type is dropped, and a
// listing action whose id isn't in THIS request's context is dropped too
// (never substituted, never guessed).

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  extractJsonObject,
  FALLBACK_REPLY,
  parseCoachOutput,
  sanitizeCoachOutput,
} from "./actions.ts";

const IDS = new Set(["listing-1", "listing-2"]);

// ── extractJsonObject ────────────────────────────────────────────────────────

Deno.test("extractJsonObject: plain JSON parses directly", () => {
  const obj = extractJsonObject('{"reply":"hi","actions":[],"suggested_replies":[]}');
  assertEquals(obj?.reply, "hi");
});

Deno.test("extractJsonObject: a ```json fence is stripped", () => {
  const obj = extractJsonObject('```json\n{"reply":"hi"}\n```');
  assertEquals(obj?.reply, "hi");
});

Deno.test("extractJsonObject: a bare ``` fence (no language tag) is stripped", () => {
  const obj = extractJsonObject('```\n{"reply":"hi"}\n```');
  assertEquals(obj?.reply, "hi");
});

Deno.test("extractJsonObject: prose before and after the object is ignored", () => {
  const obj = extractJsonObject('Sure, here you go:\n{"reply":"hi"}\nHope that helps!');
  assertEquals(obj?.reply, "hi");
});

Deno.test("extractJsonObject: a brace inside a string value doesn't end the scan early", () => {
  const obj = extractJsonObject('{"reply":"use { and } in your prompt","actions":[]}');
  assertEquals(obj?.reply, "use { and } in your prompt");
});

Deno.test("extractJsonObject: no object anywhere returns null", () => {
  assertEquals(extractJsonObject("just plain prose, no braces at all"), null);
  assertEquals(extractJsonObject(""), null);
  assertEquals(extractJsonObject("   "), null);
});

Deno.test("extractJsonObject: a bare JSON array is not treated as the object", () => {
  assertEquals(extractJsonObject('["reply","hi"]'), null);
});

// ── sanitizeCoachOutput / parseCoachOutput ──────────────────────────────────

Deno.test("sanitizeCoachOutput: a clean, valid payload passes through", () => {
  const out = sanitizeCoachOutput({
    reply: "Let's add a walkthrough video next.",
    actions: [{ type: "open_tour", label: "Open the tour", listing_id: "listing-1" }],
    suggested_replies: ["Sounds good", "What about photos?"],
  }, IDS);
  assertEquals(out.reply, "Let's add a walkthrough video next.");
  assertEquals(out.actions.length, 1);
  assertEquals(out.actions[0].type, "open_tour");
  assertEquals(out.actions[0].listing_id, "listing-1");
  assertEquals(out.suggested_replies, ["Sounds good", "What about photos?"]);
});

Deno.test("sanitizeCoachOutput: an out-of-enum action type is dropped, reply survives", () => {
  const out = sanitizeCoachOutput({
    reply: "Here's your next step.",
    actions: [{ type: "open_drone_pilot", label: "Fly a drone" }],
  }, IDS);
  assertEquals(out.reply, "Here's your next step.");
  assertEquals(out.actions.length, 0, "an invented action type must never reach the app");
});

Deno.test("sanitizeCoachOutput: a listing action whose id is not in context is dropped, not substituted", () => {
  const out = sanitizeCoachOutput({
    reply: "Opening your reel.",
    actions: [{ type: "open_reel", label: "Make a reel", listing_id: "some-other-listing" }],
  }, IDS);
  assertEquals(out.actions.length, 0, "a listing_id the caller never sent must never be honoured");
});

Deno.test("sanitizeCoachOutput: a listing action with a valid id is kept", () => {
  const out = sanitizeCoachOutput({
    reply: "Opening your reel.",
    actions: [{ type: "open_reel", label: "Make a reel", listing_id: "listing-2" }],
  }, IDS);
  assertEquals(out.actions.length, 1);
  assertEquals(out.actions[0].listing_id, "listing-2");
});

Deno.test("sanitizeCoachOutput: non-listing actions never require or keep a listing_id", () => {
  const out = sanitizeCoachOutput({
    reply: "Here's where to manage your plan.",
    actions: [{ type: "open_plan_usage", label: "Open Plan & usage", listing_id: "listing-1" }],
  }, IDS);
  assertEquals(out.actions.length, 1);
  assertEquals(out.actions[0].listing_id, undefined, "open_plan_usage carries no listing");
});

Deno.test("sanitizeCoachOutput: more than one action is clamped to exactly one", () => {
  const out = sanitizeCoachOutput({
    reply: "Two steps at once? Just one.",
    actions: [
      { type: "open_tour", label: "Open the tour", listing_id: "listing-1" },
      { type: "open_photos", label: "Open Photo Studio", listing_id: "listing-1" },
    ],
  }, IDS);
  assertEquals(out.actions.length, 1, "exactly one primary action, even if the model gave two");
  assertEquals(out.actions[0].type, "open_tour", "the first is kept, in the model's own order");
});

Deno.test("sanitizeCoachOutput: a missing/empty label falls back to a sane default per type", () => {
  const out = sanitizeCoachOutput({
    reply: "Let's get your plan sorted.",
    actions: [{ type: "open_support", label: "   " }],
  }, IDS);
  assertEquals(out.actions[0].label, "Contact support");
});

Deno.test("sanitizeCoachOutput: an empty reply falls back to FALLBACK_REPLY, never a blank bubble", () => {
  const out = sanitizeCoachOutput({ reply: "   ", actions: [] }, IDS);
  assertEquals(out.reply, FALLBACK_REPLY);
});

Deno.test("sanitizeCoachOutput: null input (nothing parsed) still returns a usable output", () => {
  const out = sanitizeCoachOutput(null, IDS);
  assertEquals(out.reply, FALLBACK_REPLY);
  assertEquals(out.actions, []);
  assertEquals(out.suggested_replies, []);
});

Deno.test("sanitizeCoachOutput: suggested_replies are de-duplicated case-insensitively and capped", () => {
  const out = sanitizeCoachOutput({
    reply: "Pick one.",
    suggested_replies: ["Yes", "yes", "No", "Maybe", "Later", "One more"],
  }, IDS);
  assertEquals(out.suggested_replies.length, 4, "capped at MAX_SUGGESTIONS");
  assertEquals(out.suggested_replies, ["Yes", "No", "Maybe", "Later"]);
});

Deno.test("sanitizeCoachOutput: a too-long reply is clamped, never dropped", () => {
  const long = "x".repeat(2000);
  const out = sanitizeCoachOutput({ reply: long }, IDS);
  assert(out.reply.length <= 700, "reply must be clamped to MAX_REPLY_CHARS");
  assert(out.reply.length > 0);
});

Deno.test("parseCoachOutput: end-to-end on a fenced, chatty model response", () => {
  const raw = 'Here you go:\n```json\n{"reply":"Nice, that\'s ready.",' +
    '"actions":[{"type":"share_tour","label":"Share it","listing_id":"listing-1"}],' +
    '"suggested_replies":["Great, thanks!"]}\n```';
  const out = parseCoachOutput(raw, IDS);
  assertEquals(out.reply, "Nice, that's ready.");
  assertEquals(out.actions[0].type, "share_tour");
  assertEquals(out.suggested_replies, ["Great, thanks!"]);
});

Deno.test("parseCoachOutput: garbage input degrades to the fallback reply, never throws", () => {
  const out = parseCoachOutput("<html>the model completely misbehaved</html>", IDS);
  assertEquals(out.reply, FALLBACK_REPLY);
  assertEquals(out.actions, []);
});

// ── Price backstop — prices come from StoreKit only, never from the model ──

Deno.test("sanitizeCoachOutput: a dollar sign in the reply is replaced and forces open_plan_usage", () => {
  const out = sanitizeCoachOutput({
    reply: "The Pro plan is $99 a month.",
    actions: [{ type: "open_tour", label: "Open the tour", listing_id: "listing-1" }],
  }, IDS);
  assert(!out.reply.includes("$"), "no dollar sign may reach the user");
  assertEquals(out.actions.length, 1);
  assertEquals(out.actions[0].type, "open_plan_usage", "a leaked price redirects to the real source");
});

Deno.test("sanitizeCoachOutput: spelling out a price in words also trips the backstop", () => {
  const out = sanitizeCoachOutput({ reply: "That plan costs 49 dollars." }, IDS);
  assertEquals(out.actions[0].type, "open_plan_usage");
});

Deno.test("sanitizeCoachOutput: an ordinary reply naming no price is untouched", () => {
  const out = sanitizeCoachOutput({
    reply: "Pro includes 10 tour renders a month.",
    actions: [{ type: "open_home", label: "Go home" }],
  }, IDS);
  assertEquals(out.reply, "Pro includes 10 tour renders a month.");
  assertEquals(out.actions[0].type, "open_home");
});

// ── The brace scanner keeps looking ─────────────────────────────────────────
//
// A model that writes prose containing a stray brace used to lose its whole
// answer: the first candidate either failed to parse (and the scan gave up on
// the spot) or parsed as some incidental `{}` with no reply, and the real
// payload after it was never reached. Both ended as FALLBACK_REPLY with the
// model's action silently dropped.

Deno.test("extractJsonObject: prose containing a broken brace does not kill the real payload", () => {
  const out = extractJsonObject('Sure, {broken} here: {"reply":"hi","actions":[]}');
  assertEquals(out?.reply, "hi");
});

Deno.test("extractJsonObject: an incidental empty object does not win over the real one", () => {
  const out = extractJsonObject(
    'The format (see { } below): {"reply":"Open your tour next.",' +
    '"actions":[{"type":"open_tour","label":"Open the tour","listing_id":"listing-1"}]}',
  );
  assertEquals(out?.reply, "Open your tour next.");
  assertEquals((out?.actions as unknown[]).length, 1);
});

Deno.test("extractJsonObject: that reply survives the whole parse, action intact", () => {
  const out = parseCoachOutput(
    'Here you go { note } {"reply":"Tag the rooms next.",' +
    '"actions":[{"type":"open_tour","label":"Open the tour","listing_id":"listing-2"}],' +
    '"suggested_replies":["What is an unbranded link?"]}',
    IDS,
  );
  assertEquals(out.reply, "Tag the rooms next.");
  assertEquals(out.actions[0].type, "open_tour");
  assertEquals(out.actions[0].listing_id, "listing-2");
  assert(out.reply !== FALLBACK_REPLY);
});

Deno.test("extractJsonObject: an object with no reply key still wins if nothing better exists", () => {
  const out = extractJsonObject('prose {"note":"no reply here"} more prose');
  assertEquals(out?.note, "no reply here");
});

Deno.test("extractJsonObject: still null when there is no object at all", () => {
  assertEquals(extractJsonObject("no braces here at all"), null);
  assertEquals(extractJsonObject("an unclosed { brace"), null);
});
