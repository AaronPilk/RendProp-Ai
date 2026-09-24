// Service-only recovery for previously authorized jobs. Never retries a paid
// submission after a committed dispatch claim. No scheduler is enabled here.
import { assert, json, readJsonLimited, respondError } from "../_shared/http.ts";
import { adminClient, isServiceRole } from "../_shared/supabase.ts";
import { createPresenterExecution } from "../studio/presenter-execution.ts";
import { presenterProduction } from "../studio/presenter-production.ts";
import { presenterRpcError } from "../studio/presenter.ts";

type DrainDeps = { authorized(req: Request): boolean; inventory(limit: number): Promise<{ jobs: { id: string }[] }>; progress(job: string): Promise<void> };
export function createPresenterDrain(deps: DrainDeps) { return async (req: Request): Promise<Response> => {
  try {
    assert(deps.authorized(req), 403, "Service role required.");
    assert(req.method === "POST", 405, "Use POST for presenter maintenance.");
    const input = await readJsonLimited(req, 4096);
    assert(Object.keys(input).every((key) => key === "limit"), 400, "Unsupported presenter maintenance input.");
    const limit = input.limit ?? 3;
    assert(Number.isSafeInteger(limit) && Number(limit) >= 1 && Number(limit) <= 3, 400, "Choose one to three jobs per maintenance request.");
    const data = await deps.inventory(Number(limit));
    assert(data && Array.isArray(data.jobs) && data.jobs.length <= Number(limit), 503, "Presenter recovery inventory is unavailable.");
    // Each retained MP4 can occupy two bounded buffers; process one job per
    // isolate at a time instead of multiplying peak media memory by the batch.
    let completed = 0;
    for (const job of data.jobs) {
      try { await deps.progress(job.id); completed++; } catch { /* next durable job remains independent */ }
    }
    // No exception bodies/URLs/provider refs are logged or returned. A partial
    // run is visible to monitoring while durable state remains recoverable.
    return json({ checked: data.jobs.length, completed, retry_pending: data.jobs.length - completed }, 200, { "Cache-Control": "no-store" });
  } catch (error) { return respondError(error); }
}; }

export const handlePresenterDrain = createPresenterDrain({
  authorized: isServiceRole,
  async inventory(limit) {
    const { data, error } = await adminClient().rpc("studio_presenter_execution_due", { p_limit: limit });
    presenterRpcError(error);
    return data;
  },
  progress: (job) => createPresenterExecution(presenterProduction()).progress(job, true),
});
