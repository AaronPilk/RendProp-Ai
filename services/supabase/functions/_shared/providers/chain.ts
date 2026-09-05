// The chain runner: try the router's steps in order, report every outcome, and
// know which failures are worth failing over from.
//
//   validation → the caller's request is wrong (bad params, missing mask, a
//                Covered Model). Asking a second vendor produces the same
//                refusal and bills us for it. RETHROWN.
//   nsfw       → a vendor refused this customer's photo. Shopping the same
//                photo around until somebody says yes is precisely the
//                behaviour a content review would hang us for. RETHROWN.
//   everything else (upstream / rate_limit / timeout / other) → the vendor is
//                having a bad day. FAIL OVER to the next step.
//
// Every attempt — success or failure — is reported to the router so the circuit
// breaker sees it. When the whole chain is exhausted the caller gets one 503
// naming the task, never a vendor's raw error.

import { type ErrorCode, HttpError } from "../http.ts";
import { type RouteContext, type RouteStep, reportOutcome, resolveRoute } from "../router.ts";
import { ProviderError, errorClassOf } from "./common.ts";

/**
 * A provider failure as an HTTP answer. ProviderError is not an HttpError, and
 * letting one reach respondError() would turn a vendor 429 into our 500.
 *
 *   validation → 400 validation          nsfw       → 400 unsupported_edit
 *   rate_limit → 429 rate_limited        everything → 502 upstream
 */
export function asHttpError(err: unknown): HttpError {
  if (err instanceof HttpError) return err;
  if (err instanceof ProviderError) {
    const code: ErrorCode = err.error_class === "validation"
      ? "validation"
      : err.error_class === "nsfw"
      ? "unsupported_edit"
      : err.error_class === "rate_limit"
      ? "rate_limited"
      : "upstream";
    return new HttpError(err.httpStatus, err.message, code);
  }
  return new HttpError(502, err instanceof Error ? err.message : String(err), "upstream");
}

export interface ChainResult<T> {
  step: RouteStep;
  value: T;
  latency_ms: number;
}

/**
 * Resolve a chain, with a hardcoded last resort.
 *
 * resolveRoute() answers `[]` when the routing table is unreadable or a task
 * has no legacy row seeded. That must NOT take a shipped feature down, so the
 * caller passes the step its own constants describe — literally today's
 * provider/model/price — and the flag-off path survives a database outage.
 */
export async function resolveChain(
  task: string,
  ctx: RouteContext,
  fallback: RouteStep,
): Promise<RouteStep[]> {
  const steps = await resolveRoute(task, ctx);
  if (steps.length > 0) return steps;
  console.warn(`router: no steps for ${task}; using the function's own legacy constants`);
  return [fallback];
}

/**
 * Run `attempt` against each step until one succeeds.
 * Throws HttpError(503) when every step has been tried.
 */
export async function runChain<T>(
  task: string,
  steps: RouteStep[],
  attempt: (step: RouteStep) => Promise<T>,
): Promise<ChainResult<T>> {
  let lastError: unknown = null;

  for (const step of steps) {
    const startedAt = Date.now();
    try {
      const value = await attempt(step);
      const latency_ms = Date.now() - startedAt;
      await reportOutcome(step, { ok: true, latency_ms });
      return { step, value, latency_ms };
    } catch (err) {
      const error_class = errorClassOf(err);
      await reportOutcome(step, { ok: false, latency_ms: Date.now() - startedAt, error_class });
      // The caller's problem, or a refusal about this exact image: stop here.
      if (error_class === "validation" || error_class === "nsfw") throw asHttpError(err);
      console.error(
        `router: ${task} step ${step.provider}/${step.model} failed (${error_class}); trying the next provider`,
      );
      lastError = err;
    }
  }

  // A CHAIN OF ONE IS NOT A CHAIN. With the flag off there is exactly one step,
  // and wrapping its failure in a new 503 would change the status, the code and
  // the message the shipped app already handles. The single-step path therefore
  // surfaces the provider's own error, unchanged in status and code.
  if (steps.length === 1 && lastError != null) throw asHttpError(lastError);

  const detail = lastError instanceof Error ? ` (last error: ${String(lastError.message).slice(0, 160)})` : "";
  throw new HttpError(
    503,
    `All providers for ${task} are unavailable right now.${detail}`,
    "upstream",
  );
}
