// No client duration reaches this authority. The service-owned receipt binds
// every ranged read and the immutable attestation to one finalized object.
import { assert, HttpError, throwRpc } from "./http.ts";
import { probeMP4Timing } from "../ai-video/mp4duration.ts";

export const TRIAL_VIDEO_CHECKER = "mp4-timing-v1";
type Scope = { actor: string; org: string; listing: string; asset: string };
type Head = { exists: boolean; bytes: number | null; etag: string | null; contentType: string | null };
type Context = { required: true; actor_id: string; org_id: string; listing_id: string; asset_id: string;
  bucket: string; storage_key: string; etag: string; bytes: number; max_video_seconds: number };
export type TrialVideoDependencies = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string } | null }>;
  head(bucket: string, key: string, signal: AbortSignal): Promise<Head>;
  sign(bucket: string, key: string, expires: number): Promise<string>;
  fetch(url: string, init: RequestInit): Promise<Response>;
  rendersBucket: string;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const sameHead = (head: Head, context: Context) => head.exists === true && head.bytes === context.bytes &&
  head.etag === context.etag && head.contentType?.split(";")[0].trim().toLowerCase() === "video/mp4";

function context(data: unknown, scope: Scope): Context | null {
  assert(data && typeof data === "object" && !Array.isArray(data), 503, "Video duration authority could not be confirmed.");
  const row = data as Record<string, unknown>;
  if (row.required === false) return null;
  assert(row.required === true && row.actor_id === scope.actor && row.org_id === scope.org &&
    row.listing_id === scope.listing && row.asset_id === scope.asset && row.bucket === "renders" &&
    typeof row.etag === "string" && row.etag.length > 0 && row.etag.length <= 256 &&
    Number.isSafeInteger(row.bytes) && Number(row.bytes) > 0 && Number(row.bytes) <= 1073741824 &&
    Number.isInteger(row.max_video_seconds) && Number(row.max_video_seconds) > 0 && Number(row.max_video_seconds) <= 90 &&
    typeof row.storage_key === "string" && row.storage_key.startsWith(`renders/${scope.org}/${scope.listing}/`) &&
    /^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.mp4$/.test(row.storage_key.split("/").at(-1) ?? "") &&
    !row.storage_key.includes(".."), 503, "Video duration authority returned an invalid owned upload.");
  return row as unknown as Context;
}

/** Returns null for paid/explicit legacy authority; never starts a worker. */
export async function attestTrialVideo(scope: Scope, deps: TrialVideoDependencies): Promise<{ duration_s: number; billable_s: number } | null> {
  try {
  assert(Object.values(scope).every(value => uuid.test(value)), 400, "Choose a valid video workspace and upload.");
  const args = { p_actor: scope.actor, p_org: scope.org, p_listing: scope.listing, p_asset: scope.asset };
  const initial = await deps.rpc("subscription_trial_video_context", args);
  if (initial.error) throwRpc(initial.error.message);
  const source = context(initial.data, scope);
  if (!source) return null;
  const deadline = Date.now() + 30000;
  const signal = () => {
    const remaining = deadline - Date.now();
    assert(remaining > 0, 409, "Video duration verification timed out.");
    return AbortSignal.timeout(Math.min(10000, remaining));
  };
  assert(sameHead(await deps.head(source.bucket, source.storage_key, signal()), source), 409,
    "The finalized video changed. Upload the saved MP4 again.");
  const signed = await deps.sign(source.bucket, source.storage_key, 300);
  const url = new URL(signed), expiry = Number(url.searchParams.get("X-Amz-Expires"));
  const expectedPath = "/" + deps.rendersBucket + "/" + source.storage_key.split("/").map(encodeURIComponent).join("/");
  assert(url.protocol === "https:" && /^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname) &&
    !url.username && !url.password && !url.hash && !url.port && url.pathname === expectedPath &&
    Number.isInteger(expiry) && expiry > 0 && expiry <= 600 &&
    /^[a-f0-9]{64}$/.test(url.searchParams.get("X-Amz-Signature") ?? ""), 503,
    "A bounded private video read could not be prepared.");
  let requests = 0, requestedBytes = 0;
  const timing = await probeMP4Timing(signed, async (target, init) => {
    assert(target === signed && init.method === "GET" && init.redirect === "error", 503, "Unexpected video read.");
    const headers = new Headers(init.headers), range = /^bytes=(\d+)-(\d+)$/.exec(headers.get("Range") ?? "");
    assert(range, 503, "A bounded video range is required.");
    const first = Number(range[1]), last = Number(range[2]);
    requestedBytes += last - first + 1;
    assert(Number.isSafeInteger(first) && Number.isSafeInteger(last) && first >= 0 && last >= first &&
      last < source.bytes && ++requests <= 65 && requestedBytes <= 2098176, 400, "Video metadata exceeded its read bound.");
    headers.set("If-Match", source.etag);
    const response = await deps.fetch(target, { ...init, headers,
      signal: AbortSignal.any([signal(), ...(init.signal ? [init.signal] : [])]) });
    const total = /^bytes \d+-\d+\/(\d+)$/.exec(response.headers.get("content-range") ?? "");
    if (Date.now() >= deadline || response.headers.get("etag") !== source.etag || !total || Number(total[1]) !== source.bytes) {
      await response.body?.cancel();
      assert(false, 409, "The video changed while its duration was checked.");
    }
    return response;
  });
  assert(Number.isFinite(timing.duration_s) && Number.isFinite(timing.billable_s) &&
    timing.duration_s > 0 && timing.billable_s > 0 &&
    Math.max(timing.duration_s, timing.billable_s) <= source.max_video_seconds, 402,
    "The trial walkthrough exceeds its verified video duration limit.");
  assert(sameHead(await deps.head(source.bucket, source.storage_key, signal()), source) && Date.now() < deadline,
    409, "The finalized video changed. Upload the saved MP4 again.");
  // The write RPC repeats current membership/deletion/receipt/source authority.
  // URLs are not written; a changed observation cannot consume an action.
  const recorded = await deps.rpc("record_subscription_trial_video", { ...args, p_bucket: source.bucket,
    p_key: source.storage_key, p_etag: source.etag, p_bytes: source.bytes,
    p_duration: timing.duration_s, p_billable: timing.billable_s, p_checker: TRIAL_VIDEO_CHECKER });
  if (recorded.error) throwRpc(recorded.error.message);
  const result = recorded.data as Record<string, unknown> | null;
  assert(result?.attested === true && result.duration_s === timing.duration_s && result.billable_s === timing.billable_s,
    503, "The verified video duration could not be recorded.");
  return timing;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    // Fetch/signing errors can contain the private presigned URL. Do not pass
    // their raw message or cause to the handler's unexpected-error logger.
    throw new HttpError(503, "The saved video could not be checked. Please retry its publication.");
  }
}
