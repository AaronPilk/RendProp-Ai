// user-copy.test.ts — the plain-language failure fields.
//
//   deno test _shared/user-copy.test.ts
//
// These fields are additive: `error` and `code` are never altered, so the
// tests here are about three promises only — (1) audit-record wording never
// reaches `user_message`, (2) `charge` says nothing the message did not say,
// (3) a saved-video status line fits the 400-byte, one-line limit both apps
// enforce before showing it.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { chargeFactFor, defaultNextStep, failureFields, hasJargon, nextStepFor, plainMessage, plainVideoMessage, supportCode } from "./user-copy.ts";
import { HttpError, json, respondError } from "./http.ts";

const TECHNICAL = [
  [503, "upstream", "The accepted photo delivery receipt could not be verified."],
  [503, "upstream", "Listing identity returned inconsistent data."],
  [409, "conflict", "The photo comparison lease changed."],
  [400, "validation", "Choose valid saved photo request and listing identities."],
  [402, "plan_required", "RP402: This workspace has no funded serving allowance"],
  [503, "upstream", "This operation could not be journaled safely. Please retry."],
  [400, "validation", "Listing lookup failed: duplicate key value violates unique constraint \"private\""],
  [502, "upstream", "Gemini 429: {\"error\":{\"code\":429}}"],
  [429, "quota_exceeded", "monthly technical upload reservation ceiling exhausted"],
] as const;

Deno.test("technical wording is replaced in user_message and never altered in place", () => {
  for (const [status, code, message] of TECHNICAL) {
    const fields = failureFields(message, code, status);
    assert(typeof fields.user_message === "string" && fields.user_message.length > 0, message);
    // The support code is the only non-sentence token a plain message may carry.
    assert(!hasJargon(fields.user_message!.replace(/ and mention code [0-9A-F]{6}/, "")), fields.user_message);
    assert(!fields.user_message!.includes("duplicate key") && !fields.user_message!.includes("{\""), fields.user_message);
    assert(fields.user_message!.length <= 400);
  }
});

Deno.test("a message that is already plain gets no user_message", () => {
  for (const message of [
    "You are editing photos very quickly. Wait a few minutes, then try again. You were not charged for this one.",
    "Sign in to continue.",
    "This tour is no longer hosted.",
  ]) assertEquals(failureFields(message, "validation", 400).user_message, undefined);
});

Deno.test("a subject that could not be checked keeps its subject", () => {
  assertEquals(plainMessage("Hosting status could not be verified. Please retry.", 503),
    "We couldn't check hosting status just now. Try again in a minute.");
  assertEquals(plainMessage("Photo review availability could not be verified. No analysis was sent.", 503),
    "We couldn't check photo review availability just now. No analysis was sent. Try again in a minute.");
});

Deno.test("charge is read only from the message's own standard sentence", () => {
  assertEquals(chargeFactFor("No edit was sent, so you were not charged. Try again."), "not_charged");
  assertEquals(chargeFactFor("We never got it back. Your credits were returned. Try again."), "credit_returned");
  assertEquals(chargeFactFor("Tap Resume to continue. You won't be charged again for that clip."), "no_new_charge");
  assertEquals(chargeFactFor("This attempt used one edit. Try the edit again."), "charged");
  assertEquals(chargeFactFor("Something went wrong on our side. Try again in a minute."), undefined);
  // A generic replacement never invents a charge statement.
  assertEquals(failureFields("The retained photo receipt is missing.", "upstream", 503).charge, undefined);
});

Deno.test("next_step is the first instruction in the message, else the default for the code", () => {
  assertEquals(nextStepFor("Wait a few minutes, then try again.", "rate_limited", 429), "retry_later");
  assertEquals(nextStepFor("Add credits, then try again.", "plan_required", 402), "add_credits");
  assertEquals(nextStepFor("Check this edit again in a moment.", "photo_quality_pending", 409), "check_saved");
  assertEquals(nextStepFor("Use a smaller copy and try again.", "payload_too_large", 413), "change_photo");
  assertEquals(nextStepFor("Nothing to say here.", "quota_exceeded", 429), "upgrade_plan");
  assertEquals(defaultNextStep("unknown_code", 503), "retry_later");
  assertEquals(defaultNextStep("unknown_code", 401), "sign_in");
});

Deno.test("explicit next_step and charge in details win; unknown values are ignored", () => {
  assertEquals(failureFields("Plain text.", "conflict", 409, { next_step: "resume", charge: "no_new_charge" }),
    { next_step: "resume", charge: "no_new_charge" });
  assertEquals(failureFields("Plain text.", "conflict", 409, { next_step: "explode", charge: "free money" }),
    { next_step: "refresh" });
});

Deno.test("phrases a shipped app matches on are never shadowed by a user_message", () => {
  for (const message of [
    "This upload is already complete and cannot be aborted",
    "parts[] must contain each part 1…4 exactly once",
    "Upload gateway is not configured and allowlisted",
  ]) assertEquals(failureFields(message, "conflict", 409).user_message, undefined);
});

Deno.test("json() adds the fields to every failure body and to nothing else", async () => {
  const refused = await json({ error: "RP402: Add credits before starting Photo Motion", code: "capacity_refused", operation_closed: false }, 402).json();
  assertEquals(refused, {
    error: "RP402: Add credits before starting Photo Motion", code: "capacity_refused", operation_closed: false,
    next_step: "add_credits", user_message: "You don't have enough credits for this yet, so it was not started. Add credits, then try again.",
  });
  assertEquals(await json({ error: "x", code: "y" }, 200).json(), { error: "x", code: "y" });
  assertEquals(await json({ error: { nested: true }, code: "y" }, 500).json(), { error: { nested: true }, code: "y" });
  assertEquals(await json([1, 2], 400).json(), [1, 2]);
  const thrown = await respondError(new HttpError(429, "Too many upload requests; try again later", "rate_limited")).json();
  assertEquals(thrown, { error: "Too many upload requests; try again later", code: "rate_limited", next_step: "retry_later" });
});

Deno.test("saved-video status lines are plain, one line and at most 400 bytes", () => {
  for (const stored of [
    "Video quality review paused. Your paid clip is saved; resume the check after processing is available.",
    "A selected photo could not be generated or approved. Your photos and payment receipts are retained.",
    "The provider receipt could not be confirmed. No duplicate generation will be started.",
    "Photo Motion could not be assembled. Your photos are kept.",
    "Background video time limit reached. Saved photos and payment receipts are retained; no duplicate generation will start.",
    "This opening timed out. Your original files are kept while the supplier outcome and credits are reconciled.",
    "Some future message that mentions a lease and an admission envelope.",
  ]) {
    const shown = plainVideoMessage(stored);
    assert(shown !== stored && !hasJargon(shown.replace(/ and mention code [0-9A-F]{6}/, "")), shown);
    assert(new TextEncoder().encode(shown).byteLength <= 400 && !/[\n\r\t]/.test(shown), shown);
  }
  // Progress lines that are already plain pass through untouched.
  const progress = "Resuming video assembly using your finished clips. No clips or quality checks are being regenerated.";
  assertEquals(plainVideoMessage(progress), progress);
  assertEquals(plainVideoMessage(null), "");
  assertEquals(supportCode("x").length, 6);
});
