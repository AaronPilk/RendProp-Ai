// Commit a priced, durable hold before ONE potentially billable video POST.
// Lost acceptance remains held and is never automatically retried/fallen over.
import { fundedAttempt, TARIFF_VERSION, type AttemptQuote } from "../_shared/funded-serving.ts";
import { HttpError, throwRpc } from "../_shared/http.ts";
import { unitsForStep } from "../_shared/ledger.ts";
import type { RoutedUsage } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { ChainResult } from "../_shared/providers/chain.ts";

export class VideoDispatchUnconfirmed extends HttpError {
  constructor() {
    super(502, "We couldn't confirm this video submission. Its processing budget remains reserved; check its status before starting another.", "upstream");
  }
}

interface ReservationOptions extends RoutedUsage {
  actorId: string;
  orgId: string;
  key: string;
  feature: "drone_render" | "aerial" | "reel";
  steps: RouteStep[];
  /** Hashed in memory; media, prompts and URLs are never stored in the journal. */
  input: unknown;
  allowance: { monthlyWindowStart: string; burstWindowStart: string };
  listingId?: string | null;
  unitCentsOverride?: (step: RouteStep) => number | undefined;
  minHoldCents?: number;
  meta?: Record<string, unknown>;
}

interface Dependencies<T extends { id: string }> {
  rpc: (name: string, args: Record<string, unknown>) => Promise<{
    data: unknown;
    error: { message?: string } | null;
  }>;
  /** Production runs the chain with exactly this ONE resolved eligible step. */
  submit: (step: RouteStep) => Promise<ChainResult<T>>;
}

export async function submitReservedVideo<T extends { id: string }>(
  options: ReservationOptions,
  deps: Dependencies<T>,
): Promise<ChainResult<T>> {
  const step = options.steps[0];
  if (!step || !["second", "minute", "call"].includes(step.unit)) {
    throw new HttpError(503, "This video route could not be priced safely. Please try again later.", "upstream");
  }
  const units = unitsForStep(step.unit, options);
  const unitCents = options.unitCentsOverride?.(step) ?? step.unit_cents;
  const total = Math.round(units * unitCents * 1e4) / 1e4;
  const hold = Math.max(total, options.minHoldCents ?? 0);
  if (![units, unitCents, total, hold].every(Number.isFinite) ||
      units <= 0 || unitCents <= 0 || total <= 0 || hold <= 0) {
    throw new HttpError(503, "This video route could not be priced safely. Please try again later.", "upstream");
  }
  const inputBytes = new TextEncoder().encode(JSON.stringify(options.input));
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", inputBytes)))
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  let reservation;
  try {
    reservation = await deps.rpc("app_video_cost_reserve_v2", {
      p_monthly_window_start: options.allowance.monthlyWindowStart,
      p_burst_window_start: options.allowance.burstWindowStart,
      p_listing: options.listingId ?? null,
      p_actor: options.actorId,
      p_org: options.orgId,
      p_key: options.key,
      p_feature: options.feature,
      p_provider: step.provider,
      p_model: step.model,
      p_input_sha256: hash,
      p_hold_cents: hold,
      p_units: units,
      p_unit_cost_cents: unitCents,
      p_meta: {
        ...(options.meta ?? {}), route_id: step.route_id, task: step.task,
        unit: step.unit, price_estimated: true,
      },
    });
  } catch {
    throw new HttpError(503, "The video budget could not be reserved. Please retry shortly.", "upstream");
  }
  if (reservation.error) {
    if (/RP(?:400|402|403|409):/.test(reservation.error.message ?? "")) throwRpc(reservation.error.message);
    throw new HttpError(503, "The video budget could not be reserved. Please retry shortly.", "upstream");
  }
  if (!reservation.data || typeof reservation.data !== "object" ||
      (reservation.data as { reserved?: unknown }).reserved !== true) {
    throw new HttpError(503, "The video budget could not be reserved. Please retry shortly.", "upstream");
  }

  let attempt: ChainResult<T>;
  let dispatched = false;
  const model = step.model.replace(/^fal-ai\//, "");
  const input = options.input as {seconds?:number;aspect?:string;resolution?:string;extra?:Record<string,unknown>};
  let quote: AttemptQuote | null = null;
  if (step.provider === "fal" && model === "topaz/upscale/video" && options.feature === "drone_render") {
    quote = {cents: Math.max(hold, (options.seconds ?? 0) * 16),version:TARIFF_VERSION};
  } else if (step.provider === "fal" && model === "bytedance/seedance/v1/pro/fast/image-to-video" && Number.isInteger(input.seconds) && input.seconds! >= 2 && input.seconds! <= 12 && ["16:9","9:16","1:1"].includes(input.aspect ?? "16:9")) {
    quote = {cents: Math.max(hold, 1920 * 1080 * (input.seconds! * 24 + 1) / 1024 / 10000),version:TARIFF_VERSION};
  } else if (step.provider === "fal" && ["veo3.1/fast/image-to-video","veo3.1/fast"].includes(model) && Number.isInteger(input.seconds) && [4,6,8].includes(input.seconds!)) {
    quote = {cents: Math.max(hold, input.seconds! * (input.resolution === "4k" ? 30 : 10)),version:TARIFF_VERSION};
  }
  try {
    // The same request must never reach a second provider after a timeout or
    // lost acceptance. ResolveChain has already applied eligibility/health.
    attempt = await fundedAttempt({actorId:options.actorId,orgId:options.orgId,requestKey:options.key,rpc:deps.rpc}, options.feature, step, options.input, quote, async () => {
      dispatched = true;
      const receipt = await deps.submit(step);
      if (typeof receipt?.value?.id !== "string" || !receipt.value.id.trim() ||
          receipt.step.provider !== step.provider || receipt.step.model !== step.model) {
        throw new Error("Unconfirmed provider receipt");
      }
      return receipt;
    });
  } catch (error) {
    const details = error instanceof HttpError ? error.details : undefined;
    const status = dispatched ? details?.provider_status : 0;
    const errorClass = dispatched ? details?.error_class : "validation";
    const rejected = (!dispatched || details?.dispatch_rejected === true) && typeof status === "number" &&
      [0, 400, 401, 402, 403, 404, 405, 413, 415, 422, 429].includes(status);
    console.error("app video submission failed", {
      provider: step.provider, model: step.model,
      provider_status: typeof status === "number" && Number.isInteger(status) && status >= 100 && status <= 599 ? status : null,
      error_class: typeof errorClass === "string" && ["upstream", "validation", "nsfw", "rate_limit", "timeout", "other"].includes(errorClass) ? errorClass : "other",
      dispatch_outcome: rejected ? "rejected" : "unconfirmed",
      rejection_phase: rejected && status === 0 ? "before_dispatch" : rejected ? "provider_answer" : null,
    });
    if (rejected) {
      // A definitive refusal did not create a billable job. Release must commit
      // before the route refunds the allowance. Failed release stays fenced.
      let releaseConfirmed = false;
      try {
        const released = await deps.rpc("app_video_cost_release_rejected", {
          p_actor: options.actorId, p_org: options.orgId, p_key: options.key,
          p_provider_status: status, p_error_class: errorClass,
        });
        releaseConfirmed = !released.error && !!released.data && typeof released.data === "object" &&
          (released.data as { released?: unknown }).released === true;
      } catch { /* Retain the hold when the release could not be confirmed. */ }
      if (releaseConfirmed) throw error;
      console.error("app video rejected submission release unavailable; priced hold retained");
    }
    // Transport errors, 5xx and malformed acceptance never authorize release.
    throw new VideoDispatchUnconfirmed();
  }
  try {
    const settled = await deps.rpc("app_video_cost_settle", {
      p_actor: options.actorId, p_org: options.orgId, p_key: options.key,
      p_provider_request_id: attempt.value.id,
    });
    if (settled.error || !settled.data || typeof settled.data !== "object" ||
        (settled.data as { settled?: unknown }).settled !== true) {
      console.error("app video ledger settlement unavailable; priced hold retained");
    }
  } catch {
    console.error("app video ledger settlement unavailable; priced hold retained");
  }
  // If settlement failed, returning the accepted receipt preserves access to
  // the output. The journal's hold still fences its entire estimated cost.
  return attempt;
}
