import { assert, HttpError } from "../_shared/http.ts";
import { assertMediaVisible } from "../_shared/media-source-access.ts";
import { entitlementFor } from "../_shared/entitlements.ts";
import { recordRoutedAiCost } from "../_shared/ledger.ts";
import { orderSteps, resolveRoute, type ChainStep, type RouteStep } from "../_shared/router.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";
import { bucketForKey } from "./handler.ts";
import { editPlanProduction } from "./edit-plan-production.ts";
import { MEDIA_ANALYSIS_LIMITS, MEDIA_ANALYSIS_TASK, type PropertyAnalysisSource, type MediaAnalysisDependencies } from "./media-analysis.ts";
import { projectChunkKey, projectMediaComplete, type ProjectMediaRow } from "./project-media.ts";
import type { StudioContext } from "./context.ts";

/** Used for both the private input object and the small provider JSON answer.
 * Content-Length is only an early refusal, never the actual memory bound. */
export async function readAnalysisBytes(response: Response, max: number, message: string): Promise<Uint8Array> {
  if (!response.ok) { await response.body?.cancel(); throw new HttpError(502, message); }
  if (Number(response.headers.get("content-length")) > max) { await response.body?.cancel(); throw new HttpError(413, message); }
  const reader = response.body?.getReader(); assert(reader, 502, message);
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) {
      const next = await reader.read(); if (next.done) break;
      size += next.value.byteLength; assert(size <= max, 413, message); chunks.push(next.value);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  const result = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

/** Read a bounded ISO-BMFF movie's own duration before dispatch. Database
 * duration_s is an upload hint and cannot authorize a paid duration by itself.
 * No fragmented streams, playlists, external references or arbitrary URLs. */
export function analysisMovieDuration(bytes: Uint8Array): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (at: number) => String.fromCharCode(...bytes.subarray(at, at + 4));
  type Box = { type: string; content: number; end: number };
  let boxCount = 0;
  function boxes(start: number, end: number): Box[] {
    const out: Box[] = [];
    for (let at = start; at < end;) {
      assert(++boxCount < 20000 && at + 8 <= end, 422, "This video container cannot be analyzed safely.");
      const raw = view.getUint32(at), type = tag(at + 4); let size = raw, header = 8;
      if (raw === 1) { assert(at + 16 <= end, 422, "The video container is incomplete."); const big = view.getBigUint64(at + 8); assert(big <= BigInt(Number.MAX_SAFE_INTEGER), 422, "The video container is too large."); size = Number(big); header = 16; }
      if (raw === 0) size = end - at;
      assert(size >= header && at + size <= end, 422, "The video container is incomplete.");
      out.push({ type, content: at + header, end: at + size }); at += size;
    }
    return out;
  }
  assert(bytes.length >= 24, 422, "Use an MP4 video for speech analysis.");
  const top = boxes(0, bytes.length);
  assert(top.some(b => b.type === "ftyp") && top.some(b => b.type === "mdat") && !top.some(b => b.type === "moof"), 422, "Use a complete MP4 or MOV video for speech analysis.");
  const movies = top.filter(b => b.type === "moov"); assert(movies.length === 1, 422, "This video has no usable movie header.");
  const movie = boxes(movies[0].content, movies[0].end);
  assert(!movie.some(b => b.type === "mvex"), 422, "Use a complete, non-fragmented MP4 video for speech analysis.");
  const headers = movie.filter(b => b.type === "mvhd"); assert(headers.length === 1, 422, "This video has no usable duration.");
  const timing = (header: Box) => {
    assert(header.content + 4 <= header.end, 422, "This video duration is incomplete.");
    const version = view.getUint8(header.content);
    assert(version === 0 || version === 1, 422, "This video header version is unsupported.");
    const scaleOffset = header.content + (version === 1 ? 20 : 12), durationOffset = scaleOffset + 4;
    assert(durationOffset + (version === 1 ? 8 : 4) <= header.end, 422, "This video duration is incomplete.");
    const scale = view.getUint32(scaleOffset), ticks = version === 1 ? Number(view.getBigUint64(durationOffset)) : view.getUint32(durationOffset);
    const seconds = ticks / scale;
    assert(Number.isSafeInteger(ticks) && Number.isFinite(seconds) && seconds > 0 && seconds <= MEDIA_ANALYSIS_LIMITS.seconds, 422, "Speech analysis supports videos up to five minutes.");
    return { scale, seconds };
  };
  const duration = timing(headers[0]).seconds;
  let audio = 0;
  for (const track of movie.filter(b => b.type === "trak")) {
    for (const mdia of boxes(track.content, track.end).filter(b => b.type === "mdia")) {
      const media = boxes(mdia.content, mdia.end), handler = media.find(b => b.type === "hdlr");
      if (!handler || handler.content + 12 > handler.end || tag(handler.content + 8) !== "soun") continue;
      assert(++audio === 1, 422, "Use an MP4 with one audio track for speech analysis.");
      const durations = media.filter(b => b.type === "mdhd"), info = media.filter(b => b.type === "minf");
      assert(durations.length === 1 && info.length === 1, 422, "This audio track has no usable timing.");
      const audioTime = timing(durations[0]);
      assert(Math.abs(audioTime.seconds - duration) <= 1, 422, "The audio and movie durations disagree. Export a complete MP4 copy.");
      const children = boxes(info[0].content, info[0].end), tables = children.filter(b => b.type === "stbl"), dataInfo = children.filter(b => b.type === "dinf");
      assert(tables.length === 1 && dataInfo.length === 1, 422, "This audio track is not a complete embedded recording.");
      const refs = boxes(dataInfo[0].content, dataInfo[0].end).filter(b => b.type === "dref");
      assert(refs.length === 1 && refs[0].content + 8 <= refs[0].end, 422, "This recording has no usable media reference.");
      const references = boxes(refs[0].content + 8, refs[0].end);
      assert(view.getUint32(refs[0].content + 4) === 1 && references.length === 1 && references[0].type === "url " && references[0].content + 4 === references[0].end && view.getUint32(references[0].content) === 1, 422, "External audio references cannot be analyzed.");
      const timeTables = boxes(tables[0].content, tables[0].end).filter(b => b.type === "stts");
      assert(timeTables.length === 1 && timeTables[0].content + 8 <= timeTables[0].end, 422, "This audio track has no complete sample timing.");
      const samples = timeTables[0], count = view.getUint32(samples.content + 4);
      assert(view.getUint32(samples.content) === 0 && count > 0 && count <= 20000 && samples.content + 8 + count * 8 === samples.end, 422, "This audio sample table cannot be analyzed safely.");
      let ticks = 0;
      for (let at = samples.content + 8; at < samples.end; at += 8) {
        const number = view.getUint32(at), delta = view.getUint32(at + 4);
        assert(number > 0 && delta > 0, 422, "The audio sample timing is invalid.");
        ticks += number * delta;
        assert(Number.isSafeInteger(ticks) && ticks / audioTime.scale <= MEDIA_ANALYSIS_LIMITS.seconds, 422, "The decoded audio would exceed five minutes.");
      }
      assert(Math.abs(ticks / audioTime.scale - audioTime.seconds) <= .1, 422, "The audio sample timing disagrees with its duration.");
    }
  }
  assert(audio, 422, "This video has no audio track. Add captions manually or choose a recording with speech.");
  return duration;
}

/** Matches the existing OpenAI adapter's Whisper multipart contract but bounds
 * the response stream and propagates cancellation. No SDK/HTTP retries. */
export async function transcribeAnalysis(step: RouteStep, bytes: Uint8Array, signal: AbortSignal, fetcher: typeof fetch = fetch): Promise<unknown> {
  assert(step.provider === "openai" && step.model === "whisper-1", 503, "The speech service is not configured for word timing.");
  const key = Deno.env.get("OPENAI_API_KEY")?.trim(); assert(key, 503, "The speech service is not configured.");
  signal.throwIfAborted();
  const form = new FormData(); form.set("file", new Blob([bytes as BlobPart], { type: "video/mp4" }), "source.mp4");
  form.set("model", step.model); form.set("response_format", "verbose_json"); form.append("timestamp_granularities[]", "word");
  let response: Response;
  try { response = await fetcher("https://api.openai.com/v1/audio/transcriptions", { method: "POST", headers: { authorization: `Bearer ${key}` }, body: form, redirect: "error", signal: AbortSignal.any([signal, AbortSignal.timeout(90_000)]) }); }
  catch { throw new HttpError(502, "Speech analysis did not finish. No automatic retry was started."); }
  if (!response.ok) { await response.body?.cancel(); throw new HttpError(502, "The speech service could not analyze this video. No automatic retry was started."); }
  const data = await readAnalysisBytes(response, MEDIA_ANALYSIS_LIMITS.responseBytes, "The speech service returned too much data.");
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data)); }
  catch { throw new HttpError(502, "The speech service returned an unreadable transcript."); }
}

/** Account project originals have no property relationship. Exact ownership is
 * required even when two collaborators upload the same content hash. */
export async function resolveAnalysisProject(context: StudioContext, id: string): Promise<ProjectMediaRow> {
  const result = await context.admin.rpc("studio_project_media_write", { p_actor: context.userId, p_org: context.orgId, p_id: id, p_action: "read", p_data: {} });
  if (result.error) {
    const status = /^RP(403|404):/.exec(result.error.message ?? "");
    throw new HttpError(status ? Number(status[1]) : 503, status ? "This saved project original is unavailable to your account." : "Saved project originals could not be checked.");
  }
  const row = result.data as ProjectMediaRow | null;
  assert(row && row.id === id && row.actor_id === context.userId && row.org_id === context.orgId, 404, "Save this original to your own account project before transcribing it.");
  assert(Number.isSafeInteger(row.bytes) && row.bytes > 0 && row.bytes <= MEDIA_ANALYSIS_LIMITS.mediaBytes && ["video/mp4", "video/quicktime"].includes(row.mime), 422, "Speech analysis needs an MP4 or MOV copy under 24 MB and five minutes.");
  assert(/^[a-f0-9]{64}$/.test(row.sha256) && projectMediaComplete(row), 422, "Finish saving this original before transcribing it.");
  return row;
}
export function sameAnalysisProject(a: ProjectMediaRow, b: ProjectMediaRow): boolean {
  return a.id === b.id && a.actor_id === b.actor_id && a.org_id === b.org_id && a.sha256 === b.sha256 && a.bytes === b.bytes && a.mime === b.mime && a.parts === b.parts &&
    Array.from({ length: a.parts }, (_, i) => [a.receipts[String(i)], b.receipts[String(i)]]).every(([x, y]) => x?.state === "complete" && y?.state === "complete" && x.sha256 === y.sha256 && x.bytes === y.bytes);
}
export async function loadAnalysisProject(row: ProjectMediaRow, signal: AbortSignal, io = { sign: presignGet, fetcher: fetch }): Promise<Uint8Array> {
  assert(row.bytes > 0 && row.bytes <= MEDIA_ANALYSIS_LIMITS.mediaBytes && projectMediaComplete(row), 422, "Finish saving a video under 24 MB before transcribing it.");
  const bytes = new Uint8Array(row.bytes), timeout = AbortSignal.any([signal, AbortSignal.timeout(45_000)]);
  let offset = 0;
  for (let i = 0; i < row.parts; i++) {
    timeout.throwIfAborted();
    const receipt = row.receipts[String(i)], url = await io.sign(R2_BUCKET_UPLOADS, projectChunkKey(row, i), 120);
    timeout.throwIfAborted();
    let response: Response;
    try { response = await io.fetcher(url, { redirect: "error", signal: timeout }); }
    catch { throw new HttpError(502, "This saved original could not be loaded. No speech analysis was started."); }
    const chunk = await readAnalysisBytes(response, receipt.bytes, "A saved original part has an invalid size.");
    timeout.throwIfAborted();
    assert(chunk.byteLength === receipt.bytes, 422, "A saved original part is incomplete.");
    const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", chunk as BufferSource))].map(b => b.toString(16).padStart(2, "0")).join("");
    assert(hash === receipt.sha256, 422, "A saved original part failed its integrity check.");
    bytes.set(chunk, offset); offset += chunk.byteLength;
  }
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(b => b.toString(16).padStart(2, "0")).join("");
  assert(offset === row.bytes && hash === row.sha256, 422, "The saved original failed its integrity check. Save the exact original again.");
  timeout.throwIfAborted(); return bytes;
}

export function mediaAnalysisProduction(context: StudioContext): MediaAnalysisDependencies {
  const { admin, db, userId, orgId } = context;
  const limit = () => Number(Deno.env.get("STUDIO_MEDIA_ANALYSIS_MAX_ESTIMATED_CENTS") ?? "0");
  const enabled = () => Deno.env.get("STUDIO_MEDIA_ANALYSIS_ENABLED") === "true" && Number.isFinite(limit()) && limit() > 0 && limit() <= 10;
  const writable = editPlanProduction(context).writable;
  const refs = (source: PropertyAnalysisSource) => ({ [source.source_kind === "asset" ? "assets" : "renders"]: [source.source_id], keys: [source.key] });
  return {
    enabled, writable,
    async route() {
      if (!enabled() || !Deno.env.get("OPENAI_API_KEY")?.trim()) return null;
      const entitlement = await entitlementFor(orgId); if (entitlement.degraded) return null;
      const routing = { plan: entitlement.plan, needs: ["stt", "word_timestamps"], carries_customer_media: true };
      const steps = orderSteps(await resolveRoute(MEDIA_ANALYSIS_TASK, routing) as ChainStep[], routing, new Map());
      const step = steps.find(s => s.enabled && s.task === MEDIA_ANALYSIS_TASK && s.provider === "openai" && s.model === "whisper-1" && s.unit === "minute" && Number.isFinite(s.unit_cents) && s.unit_cents > 0 && s.unit_cents * (MEDIA_ANALYSIS_LIMITS.seconds / 60) <= limit());
      if (!step) return null;
      const current = await admin.from("ai_routes").select("id").eq("id", step.route_id).eq("task", MEDIA_ANALYSIS_TASK).eq("enabled", true).maybeSingle();
      return !current.error && current.data ? step : null;
    },
    async resolve(input) {
      if (input.source_kind === "project_media") return { ...input, media: await resolveAnalysisProject(context, input.source_id), duration: 0 };
      const asset = input.source_kind === "asset";
      const result = await db.from(asset ? "capture_assets" : "renders").select(asset ? "id,listing_id,storage_key,bucket,kind,uploaded,duration_s" : "id,listing_id,video_key,duration_s")
        .eq("id", input.source_id).eq("listing_id", input.listing_id).maybeSingle();
      assert(!result.error && result.data, 404, "This video is unavailable.");
      const row = result.data as unknown as Record<string, unknown>, key = row[asset ? "storage_key" : "video_key"];
      const bucket = bucketForKey(key, { orgId, listingId: input.listing_id });
      assert(bucket && (!asset ? bucket === "renders" : row.bucket === bucket && row.kind === "video" && row.uploaded === true), 404, "This video is unavailable.");
      // The database hint can fail early, but load() reads the actual container.
      assert(typeof row.duration_s !== "number" || row.duration_s <= MEDIA_ANALYSIS_LIMITS.seconds, 422, "Choose a source video under five minutes.");
      return { ...input, key: key as string, bucket, duration: typeof row.duration_s === "number" ? row.duration_s : 0 };
    },
    async authorize(source) {
      if (source.source_kind === "project_media") {
        assert(sameAnalysisProject(source.media, await resolveAnalysisProject(context, source.source_id)), 409, "This saved original changed. Reopen the project before transcribing it.");
      } else await assertMediaVisible(db, source.listing_id, refs(source));
    },
    async load(source, signal) {
      if (source.source_kind === "project_media") { const bytes = await loadAnalysisProject(source.media, signal); return { bytes, duration: analysisMovieDuration(bytes) }; }
      const url = await presignGet(source.bucket === "uploads" ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS, source.key, 120);
      signal.throwIfAborted();
      let response: Response;
      try { response = await fetch(url, { redirect: "error", signal: AbortSignal.any([signal, AbortSignal.timeout(45_000)]) }); }
      catch { throw new HttpError(502, "This video could not be loaded for analysis."); }
      const bytes = await readAnalysisBytes(response, MEDIA_ANALYSIS_LIMITS.mediaBytes, "This source is too large for speech analysis. Use an MP4 copy under 24 MB.");
      return { bytes, duration: analysisMovieDuration(bytes) };
    },
    async reserve(id) {
      const bump = async (key: string, max: number, seconds: number) => {
        const value = await admin.rpc("bump_rate", { p_key: key, p_max: max, p_window_seconds: seconds, p_cost: 1 });
        assert(!value.error, 503, "Speech analysis limits could not be checked."); return value.data === true;
      };
      assert(await bump(`media-analysis:user:${userId}`, 6, 3600), 429, "Please wait before analyzing another video.");
      assert(await bump(`media-analysis:org:${orgId}`, 24, 86400), 429, "This workspace has reached today's speech analysis limit.");
      assert(await bump("media-analysis:global", 100, 86400), 429, "Today's speech analysis allowance has been reached.");
      assert(await bump(`media-analysis:request:${orgId}:${userId}:${id}`, 1, 86400), 409, "This analysis was already submitted. No automatic retry was started.");
    },
    transcribe: transcribeAnalysis,
    async record(step, seconds, outcome) {
      await recordRoutedAiCost(admin, { orgId, feature: "speech_captions", step, seconds, meta: { kind: "studio_media_analysis", attempts: 1, outcome, price_estimated: true } });
    },
  };
}
