// ai-copy — the compliance loop, and the ORDER it has to happen in.
//
// Everything here is about one rule, stated as principle 3 of ai-chapters:
//
//   MODEL-AUTHORED TEXT IS RE-CHECKED, AND WHAT TRIPS THE CHECK IS DROPPED OR
//   RETRIED — NEVER SURFACED TO THE USER AS THEIR ERROR.
//
// ai-chapters DROPS an offending chapter description and keeps the chapter,
// because a chapter is still useful without its description. A reel script has
// no such sub-part: the script IS the deliverable, so the equivalent is RETRY
// ONCE and then refuse honestly. Either way the thing the user must never see
// is a 400 blaming them for words a model wrote.
//
// The other half is ordering, and it is not cosmetic:
//
//   1. INPUT GATE, BEFORE A TOKEN IS SPENT. ai-photo's improve_prompt already
//      does this ("Refuse before spending tokens polishing something we would
//      never run", ai-photo/index.ts). Polishing "great for families" into a
//      beautifully-worded fair-housing violation costs money to produce copy we
//      then have to refuse anyway.
//   2. GENERATE.
//   3. OUTPUT GATE, BEFORE THE RESPONSE IS BUILT. A system rule is a request,
//      not a guarantee (ai-chapters/prompt.ts says the same thing) — the model
//      is told the rule in scriptInstruction(), and then it is checked.
//
// `guardedCopy()` below is the only thing that runs those three in order, which
// is why the ordering itself is under test in guard_test.ts rather than living
// as a comment in a handler.
//
// SCOPE. Both gates take the LISTING's `space_type` (never the request's own
// claim) — a bar's script is not housing advertising, and _shared/fairhousing.ts
// scopes itself on that value. null means the stricter housing rules.

import { HttpError } from "../_shared/http.ts";
import { assertFairHousing, assertMarketingCopy } from "../_shared/fairhousing.ts";

/** How many times the model gets to write compliant copy. One retry: a second
 *  refusal is a pattern, not a fluke, and a third attempt is just spend. */
export const MAX_COPY_ATTEMPTS = 2;

/**
 * Which gate the caller's INPUT gets.
 *
 *   "marketing"    — a reel script brief. assertMarketingCopy(): the script
 *                    rules AND the image-prompt denylist. 42 U.S.C. §3604(c)
 *                    covers a spoken advertisement exactly as it covers a
 *                    written listing description (see ai-voice's gate 1).
 *   "image_prompt" — a rough photo-edit idea. assertFairHousing(): the denylist
 *                    with its ADD-verb tier, which is what ai-photo's
 *                    improve_prompt has always applied to this exact text.
 */
export type CopyGate = "marketing" | "image_prompt";

/** Run the input gate. Throws 400 `unsupported_edit` naming the phrase and how
 *  to rephrase — the ONE case where the refusal is genuinely the user's to fix,
 *  because these are the user's own words. */
export function assertInputSafe(
  gate: CopyGate,
  text: string,
  what: string,
  spaceType: string | null,
): void {
  if (gate === "marketing") assertMarketingCopy(text, what, spaceType);
  else assertFairHousing(text, what, spaceType);
}

/** True when `err` is a fair-housing refusal (as opposed to a provider or
 *  network failure, which must propagate untouched). */
function isComplianceRefusal(err: unknown): boolean {
  return err instanceof HttpError && err.code === "unsupported_edit";
}

export interface GuardedCopyArgs {
  gate: CopyGate;
  /** The caller's own free text, joined. Gated before anything is spent. */
  input: string;
  /** Subject line for the INPUT refusal ("This reel brief", "That idea"). */
  inputWhat: string;
  /** Subject line for the OUTPUT check. Never reaches the user — an output
   *  refusal is answered with `refusal` below, not with the gate's own copy. */
  outputWhat: string;
  /** The LISTING's space_type, or null for the housing rules. */
  spaceType: string | null;
  /** One generation. `isRetry` is true on the second call so the caller can add
   *  a corrective line to the prompt. Anything it throws propagates. */
  attempt: (isRetry: boolean) => Promise<string>;
  /** Turn the raw model answer into the final text, or "" if unusable. */
  clean: (raw: string) => string;
  /** What the user is told when BOTH attempts trip the FAIR-HOUSING gate.
   *  Honest, and never a quotation of what the model wrote. An attempt that
   *  produced nothing usable at all gets EMPTY_REFUSAL below instead — telling
   *  someone their brief failed a compliance check when the model actually
   *  returned garbage is a lie that sends them off rewriting good copy. */
  refusal: string;
}

/** Both attempts produced nothing we could use — a broken answer, not a
 *  compliance problem. Route-independent, so it is not a caller's argument. */
export const EMPTY_REFUSAL =
  "The writing assistant didn't return anything usable this time. Try again in a moment.";

export interface GuardedCopyResult {
  text: string;
  /** 1 or 2 — how many generations this answer cost. Logged, never returned. */
  attempts: number;
  /** True when the first attempt tripped the output gate and the retry saved it. */
  retried: boolean;
}

/**
 * Input gate → generate → clean → output gate, with ONE retry, then an honest
 * refusal. Returns the compliant text.
 *
 * THROWS:
 *   400 `unsupported_edit` — the INPUT tripped the gate. Nothing was spent.
 *   502 `upstream`         — both attempts failed. `args.refusal` when the
 *                            output gate tripped, EMPTY_REFUSAL when the model
 *                            just returned nothing usable — telling someone
 *                            their brief failed a compliance check when it did
 *                            not sends them off rewriting good copy. Neither
 *                            message ever quotes what the model wrote.
 *   whatever `attempt` threw (a provider failure, a 503 from an exhausted
 *   chain) — untouched, so runChain's own error handling still means what it
 *   says.
 *
 * NOTHING ABOUT THE MODEL'S OFFENDING TEXT IS LOGGED. The whole point of the
 * loop is that the user never has to see it; writing it into a log line would
 * put a fair-housing violation in the operator's console instead, attributed to
 * an org, for no benefit — the category alone is what tells us the prompt needs
 * work.
 */
export async function guardedCopy(args: GuardedCopyArgs): Promise<GuardedCopyResult> {
  // 1. INPUT — before a token is spent.
  assertInputSafe(args.gate, args.input, args.inputWhat, args.spaceType);

  let attempts = 0;
  let sawGateTrip = false;
  for (let i = 0; i < MAX_COPY_ATTEMPTS; i++) {
    // 2. GENERATE.
    const raw = await args.attempt(i > 0);
    attempts++;
    const text = args.clean(raw);
    if (!text) {
      console.warn(`ai-copy: attempt ${attempts} produced no usable text`);
      continue;
    }
    // 3. OUTPUT — a system rule is a request, not a guarantee.
    try {
      if (args.gate === "marketing") assertMarketingCopy(text, args.outputWhat, args.spaceType);
      else assertFairHousing(text, args.outputWhat, args.spaceType);
      return { text, attempts, retried: attempts > 1 };
    } catch (e) {
      if (!isComplianceRefusal(e)) throw e;
      sawGateTrip = true;
      // The CATEGORY only — a closed vocabulary ("familial_status", "race", …).
      // Deliberately NOT `details.term`, which is the offending phrase itself:
      // that is the very text this loop exists to keep out of everyone's sight,
      // and a log line is not an exception to that.
      const category = (e as HttpError).details?.category;
      console.warn(
        `ai-copy: attempt ${attempts} tripped the fair-housing gate (${
          typeof category === "string" ? category : "denylist"
        })`,
      );
    }
  }

  throw new HttpError(502, sawGateTrip ? args.refusal : EMPTY_REFUSAL, "upstream");
}
