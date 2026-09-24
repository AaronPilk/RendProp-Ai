import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { createHfMotionTransferInput, readHfMotionTransferRef, type HfMotionTransferEstimate, type HfMotionTransferRef, type HfMotionTransferStatus } from "../_shared/providers/higgsfield.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import { mediaBytes, originalAsset, privateOutputKey, PRESENTER_VIDEO_BYTES, presenterOutputUrl, sha256, verifyPresenterOriginal, videoProbe, type MediaFetch, type MediaSign } from "./presenter-media.ts";

export type PresenterObject = Record<string, unknown>;
export interface PresenterExecutionDeps {
  user(action: string, listing: string, payload: PresenterObject): Promise<PresenterObject>;
  worker(job: string, action: string, payload?: PresenterObject): Promise<PresenterObject>;
  liveConfigured(): boolean;
  sign: MediaSign;
  fetch: MediaFetch;
  estimate(input: GenerateInput): Promise<HfMotionTransferEstimate>;
  submit(input: GenerateInput): Promise<HfMotionTransferRef>;
  poll(ref: HfMotionTransferRef): Promise<HfMotionTransferStatus>;
  cancel(ref: HfMotionTransferRef): Promise<"accepted" | "already_started">;
  outputHosts(): readonly string[];
  put(key: string, bytes: Uint8Array<ArrayBuffer>, deadline: string): Promise<void>;
  remove(key: string, bucket: "uploads" | "renders"): Promise<void>;
  upload(path: string, body: PresenterObject, requestKey?: string): Promise<PresenterObject>;
  uploadOrigin(): string;
  now?: () => number;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const headers = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };
function object(value: unknown): PresenterObject { assert(!!value && typeof value === "object" && !Array.isArray(value), 503, "Presenter job could not be read."); return value as PresenterObject; }
function id(value: unknown): string { assert(typeof value === "string" && UUID.test(value), 400, "Choose a valid presenter job or draft."); return value; }
function revision(value: unknown): number { assert(Number.isSafeInteger(value) && Number(value) > 0 && Number(value) < 2147483647, 400, "Refresh the saved revision before continuing."); return Number(value); }
function cents(value: unknown): number { assert(Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= 1_000_000, 503, "Presenter price could not be read."); return Number(value); }
function usd(value: unknown): string { return (cents(value) / 100).toFixed(2); }
function state(job: PresenterObject): string { return String(job.state ?? job.status ?? ""); }
export function presenterExecutionInput(body: PresenterObject): PresenterObject {
  const listing_id = id(body.listing_id), action = body.action;
  assert(typeof action === "string" && ["quote", "generate", "close_submission", "check", "cancel", "accept", "reject", "import"].includes(action), 400, "Choose a presenter job action.");
  const keys = ["listing_id", "action", ...(action === "quote" ? ["draft_id", "expected_revision", "expected_profile_revision"] : action === "generate" ? ["quote_id", "idempotency_key", "cost_consent", "max_cost_cents"] : action === "close_submission" ? ["quote_id", "idempotency_key"] : ["job_id", "expected_revision", ...(action === "accept" ? ["output_sha256", "output_consent"] : [])])];
  assert(Object.keys(body).every((key) => keys.includes(key)), 400, "This presenter action contains unsupported fields.");
  if (action === "quote") return { listing_id, action, draft_id: id(body.draft_id), expected_revision: revision(body.expected_revision), expected_profile_revision: revision(body.expected_profile_revision) };
  if (action === "close_submission") return { listing_id, action, quote_id: id(body.quote_id), idempotency_key: id(body.idempotency_key) };
  if (action === "generate") {
    assert(body.cost_consent === true && Number.isSafeInteger(body.max_cost_cents) && Number(body.max_cost_cents) > 0 && Number(body.max_cost_cents) <= 1_000_000, 400, "Confirm this quote's exact maximum USD cost.");
    return { listing_id, action, quote_id: id(body.quote_id), idempotency_key: id(body.idempotency_key), cost_consent: true, max_cost_cents: body.max_cost_cents };
  }
  const out = { listing_id, action, job_id: id(body.job_id), expected_revision: revision(body.expected_revision) };
  if (action !== "accept") return out;
  assert(body.output_consent === true && typeof body.output_sha256 === "string" && /^[0-9a-f]{64}$/.test(body.output_sha256), 400, "Review and approve this exact generated video.");
  return { ...out, output_sha256: body.output_sha256, output_consent: true };
}

export function createPresenterExecution(deps: PresenterExecutionDeps) {
  const now = deps.now ?? Date.now;
  function live() { assert(deps.liveConfigured(), 409, "Presenter generation is not activated. A confirmed data agreement, price and workspace budget are required."); }
  async function inputFor(prepared: PresenterObject, org: string) {
    const snapshot = object(prepared.snapshot);
    assert(snapshot.org_id === org, 503, "Presenter workspace identity changed.");
    const source = originalAsset(prepared.source_asset ?? snapshot.source_asset, org);
    const refs = prepared.reference_assets ?? snapshot.reference_assets;
    assert(Array.isArray(refs) && refs.length >= 1 && refs.length <= 8, 422, "Approve one to eight reference photos.");
    const sourceProof = await verifyPresenterOriginal(source, true, deps.sign, deps.fetch);
    const referenceKeys: string[] = [];
    // Sequential reads bound memory to one photo or video, not nine buffers.
    for (const reference of refs) {
      const asset = originalAsset(reference, org);
      await verifyPresenterOriginal(asset, false, deps.sign, deps.fetch);
      referenceKeys.push(asset.storage_key);
    }
    const spec = object(prepared.execution_spec);
    assert(spec.version === "presenter-motion-v1" && typeof spec.prompt === "string" && spec.prompt.length > 0 && ["720p", "480p"].includes(String(snapshot.resolution)), 503, "Presenter instructions changed.");
    // Recording guide text is approval context, never a visual edit instruction.
    const [videoUrl, ...urls] = await Promise.all([source.storage_key, ...referenceKeys].map((key) => deps.sign(key, 600)));
    return { probe: sourceProof.probe, input: createHfMotionTransferInput({ performanceVideoUrl: videoUrl, performanceDurationSeconds: sourceProof.probe.duration_s, approvedCharacterImageUrls: urls, reviewedPrompt: spec.prompt, resolution: snapshot.resolution as "720p" | "480p" }) };
  }

  async function dispatch(jobId: string): Promise<void> {
    live();
    const prepared = await deps.worker(jobId, "dispatch_prepare");
    if (prepared.allowed !== true) return;
    const job = object(prepared.job), org = id(job.org_id);
    const verified = await inputFor(prepared, org);
    const expected = object(prepared.probe ?? job.probe);
    assert(verified.probe.sha256 === expected.sha256 && verified.probe.bytes === expected.bytes && verified.probe.duration_s === expected.duration_s, 409, "The quoted source changed. Cancel this job and renew approval.");
    const claimed = await deps.worker(jobId, "dispatch_claim", { probe: verified.probe });
    if (claimed.claimed !== true) return;
    const token = claimed.dispatch_token ?? object(claimed.job).dispatch_token;
    // Once claim commits, even a dropped response can never issue another POST.
    // Failure to persist the receipt leaves dispatching; the drain converts it
    // to uncertain and retains the hold for manual provider reconciliation.
    let ref: HfMotionTransferRef;
    try { ref = await deps.submit(verified.input); }
    catch (error) {
      const rejected = error instanceof ProviderError && [400, 401, 402, 403, 404, 405, 413, 415, 422, 429].includes(error.status ?? 0);
      await deps.worker(jobId, rejected ? "failed" : "ambiguous", rejected
        ? { dispatch_token: token, charged_cents: 0, billing_final: true, billing_reference: `rejected_http_${(error as ProviderError).status}` }
        : { dispatch_token: token });
      return;
    }
    await deps.worker(jobId, "dispatch_result", { ...ref, dispatch_token: token });
  }

  async function cleanup(jobId: string): Promise<void> {
    const claim = await deps.worker(jobId, "cleanup_claim");
    if (claim.claimed !== true) return;
    assert(Array.isArray(claim.targets) && claim.targets.length <= 4, 503, "Presenter cleanup inventory could not be read.");
    for (const raw of claim.targets) {
      const target = object(raw);
      assert((target.bucket === "uploads" || target.bucket === "renders") && typeof target.key === "string", 503, "Presenter cleanup target is invalid.");
      // Private/output-import paths are generated by the ledger, not a client.
      assert(!/[\\%?#]/.test(target.key) && ![...target.key].some((c) => c.charCodeAt(0) < 32) && !target.key.includes("..") && (target.key.startsWith("presenter-private/") || target.key.startsWith("renders/")), 503, "Presenter cleanup scope is invalid.");
      await deps.remove(target.key, target.bucket);
    }
    await deps.worker(jobId, "cleanup_done", { cleanup_token: claim.cleanup_token, objects_deleted: true });
  }

  async function progress(jobId: string, allowDispatch = false): Promise<void> {
    let job = object((await deps.worker(jobId, "read")).job);
    let progressFailed = false, progressError: unknown;
    try {
    if (state(job) === "reserved") { if (allowDispatch && deps.liveConfigured()) await dispatch(jobId); }
    else if (state(job) === "dispatching") { await deps.worker(jobId, "sweep"); }
    else if (job.request_id && (["queued", "processing", "cancel_requested"].includes(state(job)) || (state(job) === "invalidated" && job.charged_cents === null))) {
      const ref = readHfMotionTransferRef(job);
      if (job.cancel_requested_at || state(job) === "invalidated") {
        // A lost cancel response is safe to poll. Acknowledging cancellation
        // never alone releases a financial hold; terminal status does that.
        try { await deps.cancel(ref); } catch { /* status remains authoritative */ }
      }
      const status = await deps.poll(ref);
      if (["failed", "nsfw", "canceled"].includes(status.status)) {
        await deps.worker(jobId, status.status === "canceled" ? "cancelled" : "failed", { charged_cents: 0, billing_final: true, billing_reference: `higgsfield:${ref.request_id}:${status.status}` });
      } else if (status.status === "queued" || status.status === "in_progress") {
        await deps.worker(jobId, "status", { state: status.status === "queued" ? "queued" : "processing" });
      } else if (status.status === "completed") {
        // Provider compute is finished even when its output is unwanted or the
        // download must be retried. This frees concurrency, never the cost hold.
        await deps.worker(jobId, "completed");
        const claim = await deps.worker(jobId, "output_claim");
        if (claim.claimed === true) {
          job = object(claim.job);
          const key = privateOutputKey(id(job.org_id), jobId, job.output_key);
          const url = presenterOutputUrl(status.video_url, deps.outputHosts());
          const response = await deps.fetch(url, { redirect: "error", credentials: "omit", signal: AbortSignal.timeout(60_000) });
          if (response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "video/mp4") {
            await response.body?.cancel(); throw new HttpError(502, "The generated result is not an MP4 video.");
          }
          const bytes = await mediaBytes(response, PRESENTER_VIDEO_BYTES), probe = await videoProbe(bytes, "output");
          assert(typeof claim.write_deadline === "string" && Date.parse(claim.write_deadline) > now() + 5000, 409, "The private output write lease expired. Check this job again.");
          await deps.put(key, bytes, claim.write_deadline);
          await deps.worker(jobId, "output_ready", { ...probe, lease_token: claim.lease_token });
        }
      }
    }
    } catch (error) { progressFailed = true; progressError = error; }
    // Revoked local bytes must be removed even while vendor credentials or
    // polling are unavailable. SQL still owns grace periods and write leases.
    try { await cleanup(jobId); } catch (error) { if (!progressFailed) throw error; }
    if (progressFailed) throw progressError;
  }

  async function importOutput(listing: string, payload: PresenterObject): Promise<void> {
    const prepared = await deps.user("import_prepare", listing, payload), job = object(prepared.job), jobId = id(job.id);
    if (state(job) === "imported") return;
    const key = privateOutputKey(id(job.org_id), jobId, prepared.output_key);
    const bytes = await mediaBytes(await deps.fetch(await deps.sign(key, 300), { redirect: "error", credentials: "omit", signal: AbortSignal.timeout(60_000) }), PRESENTER_VIDEO_BYTES);
    assert(bytes.length === prepared.bytes && await sha256(bytes) === prepared.sha256, 409, "The reviewed output changed. It cannot be imported.");
    const ticket = prepared.import_asset_id
      ? await deps.upload(`uploads/${id(prepared.import_asset_id)}/renew`, {})
      : await deps.upload("uploads", { listing_id: listing, filename: `presenter-${jobId}.mp4`, kind: "video", role: "render", bytes: bytes.length, content_type: "video/mp4", sha256: prepared.sha256, duration_s: prepared.duration_s }, `presenter-import:${jobId}`);
    const assetId = id(ticket.asset_id);
    await deps.worker(jobId, "import_bind", { asset_id: assetId });
    if (ticket.uploaded !== true) {
      assert(ticket.mode === "single" && typeof ticket.put_url === "string", 502, "The presenter upload ticket is unavailable.");
      const destination = new URL(ticket.put_url);
      assert(destination.origin === deps.uploadOrigin() && destination.protocol === "https:" && !destination.username && !destination.password && !destination.hash && /^\/v2\/[a-f0-9-]{36}$/.test(destination.pathname), 502, "The presenter upload destination is invalid.");
      // Re-authorize immediately before writing. Publication is additionally
      // fenced by the SQL asset marker trigger if approval is revoked mid-PUT.
      await deps.worker(jobId, "import_bind", { asset_id: assetId });
      const put = await deps.fetch(destination.href, { method: "PUT", headers: { "content-type": "video/mp4" }, body: bytes, redirect: "error", signal: AbortSignal.timeout(120_000) });
      await put.body?.cancel();
      assert(put.ok, 502, "The presenter upload paused. Check the saved job to resume it.");
      await deps.upload(`uploads/${assetId}/complete`, { sha256: prepared.sha256, duration_s: prepared.duration_s, bytes: bytes.length }, `complete:${assetId}`);
    }
    await deps.worker(jobId, "import_commit", { asset_id: assetId });
  }

  async function envelope(listing: string, includeJob?: string): Promise<PresenterObject> {
    const data = await deps.user("get", listing, {});
    assert(data.listing_id === listing && typeof data.org_id === "string" && Array.isArray(data.jobs) && data.jobs.length <= 100 && Array.isArray(data.quotes) && data.quotes.length <= 100, 503, "Presenter jobs could not be read.");
    const runtime = object(data.runtime);
    if (!deps.liveConfigured()) Object.assign(runtime, { available: false, code: "presenter_not_activated", reason: "AI generation is not activated. A confirmed data agreement, price and workspace budget are required." });
    const quotes = data.quotes.map((raw) => { const q = object(raw); return { ...q, estimate_usd: usd(q.quote_cents), consumed: q.consumed === true }; });
    if (includeJob && !data.jobs.some((job) => object(job).id === includeJob)) {
      const included = await deps.user("get", listing, { job_id: includeJob });
      assert(Array.isArray(included.jobs) && included.jobs.length === 1 && object(included.jobs[0]).id === includeJob, 404, "Presenter job is unavailable.");
      data.jobs.unshift(included.jobs[0]);
      if (data.jobs.length > 100) data.jobs.pop();
    }
    const jobs: PresenterObject[] = [];
    for (const raw of data.jobs) {
      const job = object(raw), permissions = object(job.permissions);
      const dto = { ...job, status: state(job), estimate_usd: usd(job.quote_cents), actual_usd: job.charged_cents === null ? null : usd(job.charged_cents), imported_asset_id: job.imported_asset_id ?? job.asset_id ?? null };
      if (permissions.can_preview === true) {
        const before = await deps.user("preview", listing, { job_id: id(job.id) });
        const key = privateOutputKey(id(data.org_id), id(job.id), before.output_key);
        const preview_url = await deps.sign(key, 300);
        const after = await deps.user("preview", listing, { job_id: job.id });
        assert(JSON.stringify(before) === JSON.stringify(after), 409, "Presenter approval changed. Reload before reviewing.");
        Object.assign(dto, { output: { sha256: before.sha256, bytes: before.bytes, duration_s: before.duration_s, preview_url, preview_expires_at: new Date(now() + 300_000).toISOString() } });
      }
      jobs.push(dto);
    }
    return { org_id: data.org_id, listing_id: listing, runtime, quotes, jobs };
  }

  async function action(listing: string, payload: PresenterObject): Promise<PresenterObject> {
    const kind = payload.action;
    let includeJob: string | undefined, closed: PresenterObject | undefined;
    if (kind === "quote") {
      live();
      const prepared = await deps.user("quote_prepare", listing, payload);
      assert(object(prepared.runtime).available === true, 409, "Presenter generation is not activated.");
      const snapshot = object(prepared.snapshot), verified = await inputFor(prepared, id(snapshot.org_id));
      const current = await deps.user("quote_prepare", listing, payload);
      assert(JSON.stringify(current.snapshot) === JSON.stringify(prepared.snapshot) && JSON.stringify(current.execution_spec) === JSON.stringify(prepared.execution_spec) && current.price_version === prepared.price_version && current.max_cost_cents === prepared.max_cost_cents && object(current.runtime).revision === object(prepared.runtime).revision && object(current.runtime).available === true, 409, "Presenter approval or pricing changed. Refresh before requesting a quote.");
      const estimate = await deps.estimate(verified.input);
      await deps.user("quote_commit", listing, { ...payload, quote_id: crypto.randomUUID(), quote_cents: estimate.ceilingCents, price_version: prepared.price_version ?? object(prepared.runtime).price_version, probe: verified.probe, execution_spec: prepared.execution_spec });
    } else if (kind === "generate") {
      live();
      const created = await deps.user("create", listing, payload);
      includeJob = id(object(created.job).id);
      // A replay returns the same durable job. Never repeat an uncertain POST.
      if (created.replayed !== true) await progress(id(object(created.job).id), true);
    } else if (kind === "close_submission") {
      const result = await deps.user("close_submission", listing, payload);
      if (result.job) includeJob = id(object(result.job).id);
      if (result.closed_submission) {
        closed = object(result.closed_submission);
        assert(closed.quote_id === payload.quote_id && closed.idempotency_key === payload.idempotency_key, 503, "Submission closure could not be confirmed.");
      }
    } else if (kind === "check") {
      const visible = await deps.user("get", listing, { job_id: payload.job_id });
      assert(Array.isArray(visible.jobs) && visible.jobs.some((j) => object(j).id === payload.job_id), 404, "Presenter job is unavailable.");
      await progress(id(payload.job_id), true);
    } else if (kind === "import") await importOutput(listing, payload);
    else {
      await deps.user(String(kind), listing, payload);
      if (kind === "cancel" || kind === "reject") await progress(id(payload.job_id));
    }
    return { ...await envelope(listing, includeJob ?? (typeof payload.job_id === "string" ? payload.job_id : undefined)), ...(closed ? { closed_submission: { quote_id: closed.quote_id, idempotency_key: closed.idempotency_key } } : {}) };
  }
  return { action, envelope, progress, cleanup };
}

export async function presenterJobsRequest(req: Request, deps: PresenterExecutionDeps, authorize: (listing: string) => Promise<void>): Promise<Response | null> {
  const seg = pathSegments(req, "studio");
  if (seg.length !== 2 || seg[0] !== "presenter" || seg[1] !== "jobs") return null;
  assert(req.method === "GET" || req.method === "POST", 405, "Use a presenter job action.");
  const payload = req.method === "POST" ? presenterExecutionInput(await readJsonLimited(req, 8192)) : null;
  const listing = payload ? id(payload.listing_id) : id(new URL(req.url).searchParams.get("listing_id"));
  await authorize(listing);
  const execution = createPresenterExecution(deps);
  return json(payload ? await execution.action(listing, payload) : await execution.envelope(listing), 200, headers);
}
