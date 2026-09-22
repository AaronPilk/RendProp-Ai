// ai-copy — compliance-loop tests.
//
//   deno test services/supabase/functions/ai-copy/guard_test.ts
//
// Pure — no env, no network, no Supabase. `guardedCopy()` takes the generation
// as a callback, so these tests drive the WHOLE ordering with a counting fake
// and assert the two properties the loop exists for:
//
//   • AN INPUT THAT TRIPS THE GATE IS REFUSED BEFORE A TOKEN IS SPENT. Asserted
//     by counting the generations, not by reading the comment above the call —
//     "before any spend" is only true if the callback never runs.
//   • MODEL-AUTHORED TEXT THAT TRIPS THE GATE IS RETRIED ONCE AND THEN REFUSED,
//     never returned and never handed back to the user as a 400 they caused.
//     This is ai-chapters principle 3 (the offending text was written by a
//     model; there is nothing for the user to fix).

import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { EMPTY_REFUSAL, MAX_COPY_ATTEMPTS, assertInputSafe, guardedCopy } from "./guard.ts";

/** A generation that counts its calls and can be told what to answer. */
function fakeModel(answers: string[]) {
  const calls: boolean[] = []; // one entry per call: was it the retry?
  return {
    calls,
    attempt: (isRetry: boolean): Promise<string> => {
      calls.push(isRetry);
      return Promise.resolve(answers[Math.min(calls.length - 1, answers.length - 1)]);
    },
  };
}

const CLEAN_SCRIPT = "Four bedrooms open onto the water. The kitchen was rebuilt last year. Book a showing.";
const TRIPS_SCRIPT = "Great for families, and a safe neighborhood too.";
const CLEAN_PROMPT = "Repaint the kitchen cabinets a soft matte white, keeping the hardware and worktops identical.";
const TRIPS_PROMPT = "add a family in the living room";

const base = {
  gate: "marketing" as const,
  inputWhat: "This reel brief",
  outputWhat: "This script",
  spaceType: null,
  clean: (raw: string) => raw.trim(),
  refusal: "We couldn't write a script for this one that clears the fair-housing rules.",
};

// ── The input gate: refused BEFORE anything is spent ─────────────────────────

Deno.test("input gate: a script brief that trips fair housing spends NOTHING", async () => {
  const model = fakeModel([CLEAN_SCRIPT]);
  const err = await assertRejects(
    () => guardedCopy({ ...base, input: TRIPS_SCRIPT, attempt: model.attempt }),
    HttpError,
  );
  assertEquals(err.status, 400);
  assertEquals(err.code, "unsupported_edit");
  // THE assertion: the model was never called, so nothing was billed.
  assertEquals(model.calls.length, 0);
  // The refusal names the offending phrase, because these are the USER's own
  // words and this is the one refusal they can actually act on.
  assertStringIncludes(err.message, "Great for families");
});

Deno.test("input gate: an image-edit idea that trips the denylist spends NOTHING", async () => {
  const model = fakeModel([CLEAN_PROMPT]);
  const err = await assertRejects(
    () =>
      guardedCopy({
        ...base,
        gate: "image_prompt",
        inputWhat: "That idea",
        outputWhat: "That edit",
        input: TRIPS_PROMPT,
        attempt: model.attempt,
      }),
    HttpError,
  );
  assertEquals(err.status, 400);
  assertEquals(err.code, "unsupported_edit");
  assertEquals(model.calls.length, 0);
});

Deno.test("assertInputSafe: the gate is chosen by route, and both let clean text through", () => {
  assertInputSafe("marketing", CLEAN_SCRIPT, "This reel brief", null);
  assertInputSafe("image_prompt", CLEAN_PROMPT, "That idea", null);

  // The SCOPE argument is the listing's space type, and a non-housing listing
  // keeps only the general safety layer: "adults only" is a bar's legal reality.
  assertInputSafe("marketing", "Adults only after 9pm. Seats 220 guests.", "This reel brief", "venue");
  assertThrows(
    () => assertInputSafe("marketing", "Adults only.", "This reel brief", null),
    HttpError,
  );
});

Deno.test("input gate runs before the model even when the input is only PART of the brief", async () => {
  // The gate reads the joined free text (tagline + region + details + tags), so
  // a violation hidden in one detail field still stops the spend.
  const model = fakeModel([CLEAN_SCRIPT]);
  await assertRejects(
    () =>
      guardedCopy({
        ...base,
        input: "Water on three sides. Sausalito, CA. Vibe: perfect for families.",
        attempt: model.attempt,
      }),
    HttpError,
  );
  assertEquals(model.calls.length, 0);
});

// ── The output gate: retried once, then refused ──────────────────────────────

Deno.test("output gate: clean copy is returned on the first attempt", async () => {
  const model = fakeModel([CLEAN_SCRIPT]);
  const out = await guardedCopy({ ...base, input: "Water on three sides.", attempt: model.attempt });
  assertEquals(out.text, CLEAN_SCRIPT);
  assertEquals(out.attempts, 1);
  assertEquals(out.retried, false);
  assertEquals(model.calls, [false]);
});

Deno.test("output gate: a first answer that trips is RETRIED, and the retry is used", async () => {
  const model = fakeModel([TRIPS_SCRIPT, CLEAN_SCRIPT]);
  const out = await guardedCopy({ ...base, input: "Water on three sides.", attempt: model.attempt });
  assertEquals(out.text, CLEAN_SCRIPT);
  assertEquals(out.attempts, 2);
  assertEquals(out.retried, true);
  // The second call is flagged as the retry, so the caller can add its
  // corrective line to the prompt.
  assertEquals(model.calls, [false, true]);
});

Deno.test("output gate: two bad answers are REFUSED, never returned", async () => {
  const model = fakeModel([TRIPS_SCRIPT, "Safe neighborhood, great for families."]);
  const err = await assertRejects(
    () => guardedCopy({ ...base, input: "Water on three sides.", attempt: model.attempt }),
    HttpError,
  );
  // 502, not 400: the model wrote it, so it is OUR failure, not the user's.
  assertEquals(err.status, 502);
  assertEquals(err.code, "upstream");
  assertEquals(err.message, base.refusal);
  // …and exactly one retry, never a third paid attempt.
  assertEquals(model.calls.length, MAX_COPY_ATTEMPTS);
  assertEquals(MAX_COPY_ATTEMPTS, 2);
});

Deno.test("output refusal never quotes the offending copy back at the user", async () => {
  const model = fakeModel([TRIPS_SCRIPT]);
  const err = await assertRejects(
    () => guardedCopy({ ...base, input: "Water on three sides.", attempt: model.attempt }),
    HttpError,
  );
  assert(
    !err.message.includes("Great for families"),
    "the user must never be shown copy a model wrote and we refused",
  );
  assert(!err.message.includes(TRIPS_SCRIPT));
  assertEquals(err.details, undefined);
});

Deno.test("output gate: an unusable (empty) answer also costs exactly one retry", async () => {
  const model = fakeModel(["   ", CLEAN_SCRIPT]);
  const out = await guardedCopy({ ...base, input: "Water on three sides.", attempt: model.attempt });
  assertEquals(out.text, CLEAN_SCRIPT);
  assertEquals(out.attempts, 2);

  const dead = fakeModel(["", ""]);
  await assertRejects(
    () => guardedCopy({ ...base, input: "Water on three sides.", attempt: dead.attempt }),
    HttpError,
  );
  assertEquals(dead.calls.length, MAX_COPY_ATTEMPTS);
});

Deno.test("a broken answer is NOT reported as a fair-housing refusal", async () => {
  // Telling someone their brief failed a compliance check when the model
  // actually returned garbage sends them off rewriting perfectly good copy.
  const dead = fakeModel(["", ""]);
  const err = await assertRejects(
    () => guardedCopy({ ...base, input: "Water on three sides.", attempt: dead.attempt }),
    HttpError,
  );
  assertEquals(err.status, 502);
  assertEquals(err.message, EMPTY_REFUSAL);
  assert(err.message !== base.refusal);
  assert(!err.message.includes("fair-housing"));
});

Deno.test("a JSON object with the WRONG shape is unusable, not silently spoken", async () => {
  // `{"prompt": …}` on the script route, or a non-string `script`: the raw JSON
  // must never become the script — it would be read out loud as JSON.
  const clean = (raw: string) => {
    const obj = JSON.parse(raw) as Record<string, unknown>;
    return typeof obj.script === "string" ? obj.script : "";
  };
  const model = fakeModel(['{"prompt":"wrong key"}', '{"script":"Right key. Book a showing."}']);
  const out = await guardedCopy({ ...base, clean, input: "Water on three sides.", attempt: model.attempt });
  assertEquals(out.text, "Right key. Book a showing.");
  assertEquals(out.attempts, 2);
});

Deno.test("output gate is SCOPED by the listing: a venue keeps only the general layer", async () => {
  // "Adults only" is a bar's legal reality, not housing steering — the same
  // scoping ai-voice applies. Housing (null) refuses it; a venue does not.
  const venue = fakeModel(["Adults only after nine. Seats 220 guests. Plan your event."]);
  const out = await guardedCopy({
    ...base,
    spaceType: "venue",
    input: "Late-night bar",
    attempt: venue.attempt,
  });
  assertEquals(out.attempts, 1);

  const housing = fakeModel(["Adults only after nine.", "Adults only after nine."]);
  await assertRejects(
    () => guardedCopy({ ...base, spaceType: null, input: "A quiet street", attempt: housing.attempt }),
    HttpError,
  );
  assertEquals(housing.calls.length, MAX_COPY_ATTEMPTS);
});

// ── Provider failures are NOT compliance failures ────────────────────────────

Deno.test("a provider failure propagates untouched — it is not retried as a refusal", async () => {
  // runChain() already tried every step and gave up; wrapping its 503 in a
  // fair-housing refusal would tell the user their words were the problem.
  let calls = 0;
  const err = await assertRejects(
    () =>
      guardedCopy({
        ...base,
        input: "Water on three sides.",
        attempt: () => {
          calls++;
          return Promise.reject(new HttpError(503, "All providers for copy.reel_script are unavailable right now.", "upstream"));
        },
      }),
    HttpError,
  );
  assertEquals(err.status, 503);
  assertStringIncludes(err.message, "All providers");
  assertEquals(calls, 1, "a vendor outage must not be retried here — runChain already did that");
});

Deno.test("a non-HttpError thrown by the generation is not swallowed", async () => {
  await assertRejects(
    () =>
      guardedCopy({
        ...base,
        input: "Water on three sides.",
        attempt: () => Promise.reject(new TypeError("boom")),
      }),
    TypeError,
  );
});
