// Coach-only limits. Provider tariffs and the shared money authority stay in
// funded-serving.ts; a route row cannot enlarge this support call's budget.
import type { RouteStep } from "../_shared/router.ts";
import { paramsOf } from "../_shared/router.ts";
import { HttpError } from "../_shared/http.ts";
import { routeCatalogQuote, textAttemptQuote, type AttemptQuote } from "../_shared/funded-serving.ts";
import { buildUserTurn, type UserTurnArgs } from "./prompt.ts";

export const COACH_MAX_OUTPUT_TOKENS = 600;
export const COACH_MAX_PROMPT_BYTES = 26_624;
export const COACH_MAX_ATTEMPTS = 2;
export const COACH_MAX_ATTEMPT_CENTS = 8;

export function coachPromptBytes(system: string, turn: string): number {
  // Exact combined OpenAI text; Anthropic's system+text uses fewer delimiter bytes.
  return new TextEncoder().encode(`${system}\n\n---\n\n${turn}`).byteLength;
}

/** GPT-5.6+ implicitly writes its cold prompt cache at 1.25x input.
 * Multiplying the entire published text bound also covers that premium without
 * depending on a cache hit or changing shared adapter/cache behavior. The small
 * extra output reserve is deliberate; this is a hold, not an invoice. Claude's
 * current request has no cache_control and uses its base text quote. */
export function coachAttemptQuote(step: RouteStep, system: string, turn: string): AttemptQuote | null {
  const quote = textAttemptQuote(step, system, turn, COACH_MAX_OUTPUT_TOKENS);
  return quote && step.provider === "openai" ? {cents: quote.cents * 1.25, version: `${quote.version}-coach-cold-cache-bound`} : quote;
}

/** Drop old conversation first, then other project hints, keeping the latest
 * user request and selected project. Never truncate the actual newest question. */
export function boundedCoachTurn(system: string, args: UserTurnArgs): string {
  const history = [...args.history];
  const listings = [...args.context.listings];
  for (;;) {
    const turn = buildUserTurn({...args, history, context: {...args.context, listings}});
    if (coachPromptBytes(system, turn) <= COACH_MAX_PROMPT_BYTES) return turn;
    if (history.length > 1) { history.shift(); continue; }
    const removable = listings.findLastIndex(l => l.id !== args.context.selectedListingId);
    if (removable >= 0) { listings.splice(removable, 1); continue; }
    throw new HttpError(400, "This help request is too long. Ask one shorter question.", "validation");
  }
}

/** At most two steps, in the router's eligible order. Both adapters consume
 * this same pinned params object and the quote uses their actual token cap.
 * Unknown/expensive/unpriced routes fail before any provider or funding hold. */
export function boundedCoachChain(steps: RouteStep[], system: string, turn: string): RouteStep[] {
  if (coachPromptBytes(system, turn) > COACH_MAX_PROMPT_BYTES) throw new HttpError(400, "This help request is too long.", "validation");
  const bounded = steps.slice(0, COACH_MAX_ATTEMPTS).map(step => ({
    ...step, params: {...paramsOf(step), max_output_tokens: COACH_MAX_OUTPUT_TOKENS},
  }));
  if (!bounded.length) throw new HttpError(503, "Online help is temporarily unavailable. Use the app's local help or Contact support.", "upstream");
  for (const step of bounded) {
    const quote = coachAttemptQuote(step, system, turn);
    const catalog = routeCatalogQuote(step, {system, userTurn: turn});
    if (!["anthropic", "openai"].includes(step.provider) || !quote || !catalog || step.unit !== "call" || quote.cents > COACH_MAX_ATTEMPT_CENTS || catalog.cents > COACH_MAX_ATTEMPT_CENTS) {
      throw new HttpError(503, "Online help is temporarily unavailable. Use the app's local help or Contact support.", "upstream");
    }
  }
  return bounded;
}
