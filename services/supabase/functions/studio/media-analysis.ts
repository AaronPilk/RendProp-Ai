import { assert, HttpError, json, readJsonLimited } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { StudioContext } from "./context.ts";
import type { ProjectMediaRow } from "./project-media.ts";

export const MEDIA_ANALYSIS_LIMITS = { requestBytes: 2048, mediaBytes: 24_000_000, responseBytes: 256 * 1024, seconds: 300, words: 1500 } as const;
export const MEDIA_ANALYSIS_TASK = "stt.captions";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export type PropertyAnalysisInput = { listing_id: string; source_id: string; source_kind: "asset" | "render" };
export type ProjectAnalysisInput = { source_id: string; source_kind: "project_media" };
export type MediaAnalysisInput = PropertyAnalysisInput | ProjectAnalysisInput;
export type AnalysisWord = { text: string; start: number; end: number };
export type AnalysisSegment = { id: string; start: number; end: number; text: string };
export type AnalysisHighlight = { segmentIds: string[]; start: number; end: number; reason: string };
export type PropertyAnalysisSource = PropertyAnalysisInput & { key: string; bucket: "uploads" | "renders"; duration: number };
export type AnalysisSource = PropertyAnalysisSource | (ProjectAnalysisInput & { media: ProjectMediaRow; duration: number });
export type AnalysisResult = {
  sourceId: string; sourceKind: "asset" | "render" | "project_media"; sourceFingerprint: string; duration: number;
  words: AnalysisWord[]; segments: AnalysisSegment[]; highlights: AnalysisHighlight[];
  method: "speech"; reviewRequired: true; warnings: string[];
};

export function mediaAnalysisInput(raw: unknown): MediaAnalysisInput {
  assert(raw && typeof raw === "object" && !Array.isArray(raw), 400, "Choose a saved property video to analyze.");
  const v = raw as Record<string, unknown>;
  if (v.source_kind === "project_media") {
    assert(Object.keys(v).every(k => ["source_id", "source_kind"].includes(k)) && typeof v.source_id === "string" && UUID.test(v.source_id), 400, "Choose a saved account video. Only its source identity is accepted.");
    return { source_id: v.source_id, source_kind: "project_media" };
  }
  assert(Object.keys(v).every(k => ["listing_id", "source_id", "source_kind"].includes(k)), 400, "Only a saved source identity is accepted.");
  assert(typeof v.listing_id === "string" && UUID.test(v.listing_id) && typeof v.source_id === "string" && UUID.test(v.source_id), 400, "Choose a saved property video to analyze.");
  assert(v.source_kind === "asset" || v.source_kind === "render", 400, "Choose an uploaded video or finished render.");
  return { listing_id: v.listing_id, source_id: v.source_id, source_kind: v.source_kind };
}

/** Reject bad timing as a whole. Sorting, clamping or dropping words can make
 * a plausible subtitle track that no longer corresponds to the source audio. */
export function validatedWords(raw: unknown, duration: number): AnalysisWord[] {
  assert(Array.isArray(raw) && raw.length <= MEDIA_ANALYSIS_LIMITS.words, 502, "The transcript exceeded its word limit.");
  let end = 0;
  return raw.map(value => {
    assert(value && typeof value === "object" && !Array.isArray(value), 502, "The transcript contains unreadable words.");
    const w = value as Record<string, unknown>, text = w.word ?? w.text;
    assert(typeof text === "string" && !!text.trim() && text.trim().length <= 80 && !/[\u0000-\u001f\u007f]/.test(text), 502, "The transcript contains invalid text.");
    assert(typeof w.start === "number" && typeof w.end === "number" && Number.isFinite(w.start) && Number.isFinite(w.end) && w.start >= end && w.end > w.start && w.end <= duration + .05, 502, "The transcript timing does not match this video.");
    end = w.end;
    return { text: text.trim(), start: w.start, end: w.end };
  });
}

export function speechSegments(words: AnalysisWord[]): AnalysisSegment[] {
  const out: AnalysisSegment[] = []; let group: AnalysisWord[] = [];
  const flush = () => { if (!group.length) return; out.push({ id: `speech-${out.length + 1}`, start: group[0].start, end: group[group.length - 1].end, text: group.map(w => w.text).join(" ") }); group = []; };
  for (const word of words) {
    const previous = group.at(-1);
    if (previous && (word.start - previous.end > .65 || word.end - group[0].start > 7 || [...group.map(w => w.text), word.text].join(" ").length > 120)) flush();
    group.push(word);
    if (/[.!?]["')\]]?$/.test(word.text)) flush();
  }
  flush(); return out;
}

/** These are speaking passages, not visual quality rankings. All labels quote
 * source evidence; no model invents rooms, property facts or shot boundaries. */
export function speechHighlights(segments: AnalysisSegment[]): AnalysisHighlight[] {
  return segments.filter(s => s.end - s.start >= 1.5 && s.text.split(/\s+/).length >= 4).map(segment => ({
    segment, score: (/\b(kitchen|living|bedroom|bathroom|garden|terrace|view|office|studio|space|light|open house|showing|tour)\b/i.test(segment.text) ? 2 : 0) + (/[.!?]["')\]]?$/.test(segment.text) ? 1 : 0),
  })).sort((a, b) => b.score - a.score || a.segment.start - b.segment.start).slice(0, 5).map(({ segment }) => ({
    segmentIds: [segment.id], start: segment.start, end: segment.end,
    reason: `Spoken passage: “${segment.text}”. Review the picture and speech before using it.`,
  }));
}

export function analysisOutput(raw: unknown, source: AnalysisSource, fingerprint: string, duration: number): AnalysisResult {
  assert(raw && typeof raw === "object" && !Array.isArray(raw), 502, "The speech service returned an unreadable transcript.");
  const data = raw as Record<string, unknown>;
  assert(typeof data.duration === "number" && Number.isFinite(data.duration) && data.duration > 0 && data.duration <= MEDIA_ANALYSIS_LIMITS.seconds && Math.abs(data.duration - duration) <= Math.max(1, duration * .02), 502, "The transcript duration does not match this source.");
  const words = validatedWords(data.words, duration), segments = speechSegments(words);
  assert(/^[a-f0-9]{64}$/.test(fingerprint), 502, "The source fingerprint could not be verified.");
  return { sourceId: source.source_id, sourceKind: source.source_kind, sourceFingerprint: fingerprint, duration, words, segments, highlights: speechHighlights(segments), method: "speech", reviewRequired: true,
    warnings: words.length ? ["Check names, numbers and wording before applying captions. Speech suggestions do not assess picture quality or verify property claims."] : ["No timed speech was detected. The edit has not changed."] };
}

export type MediaAnalysisDependencies = {
  enabled(): boolean; writable(): Promise<boolean>; route(): Promise<RouteStep | null>;
  resolve(input: MediaAnalysisInput): Promise<AnalysisSource>;
  authorize(source: AnalysisSource): Promise<void>;
  load(source: AnalysisSource, signal: AbortSignal): Promise<{ bytes: Uint8Array; duration: number }>;
  reserve(requestId: string): Promise<void>;
  transcribe(step: RouteStep, bytes: Uint8Array, signal: AbortSignal): Promise<unknown>;
  record(step: RouteStep, seconds: number, outcome: "returned" | "uncertain"): Promise<void>;
};
export async function handleMediaAnalysis(req: Request, context: StudioContext, deps: MediaAnalysisDependencies): Promise<Response> {
  assert(req.method === "GET" || req.method === "POST", 405, "Check availability or submit a saved video.");
  const writable = await deps.writable(), enabled = deps.enabled(), route = writable && enabled ? await deps.route() : null;
  const reason = !writable ? "read_only" : !enabled ? "disabled" : !route ? "unconfigured" : null;
  if (req.method === "GET") return json({ available: reason === null, reason, maxBytes: MEDIA_ANALYSIS_LIMITS.mediaBytes, maxSeconds: MEDIA_ANALYSIS_LIMITS.seconds, method: "speech", reviewRequired: true }, 200, { "Cache-Control": "private, no-store" });
  assert(writable, 403, "Your role cannot analyze or edit videos.");
  assert(enabled && route, 503, "Speech captions are not enabled for this workspace.");
  const input = mediaAnalysisInput(await readJsonLimited(req, MEDIA_ANALYSIS_LIMITS.requestBytes));
  const requestId = req.headers.get("Idempotency-Key") ?? "";
  assert(UUID.test(requestId), 400, "This analysis needs a new request identifier.");
  req.signal.throwIfAborted();
  if ("listing_id" in input) await context.authorizeListing(input.listing_id);
  const source = await deps.resolve(input);
  assert(source.source_id === input.source_id && source.source_kind === input.source_kind && (!("listing_id" in input) || ("listing_id" in source && source.listing_id === input.listing_id)), 403, "The video source did not match.");
  await deps.authorize(source);
  // Reserve before storage IO, so duplicate/parallel requests cannot repeatedly
  // download the private object or charge a second provider attempt.
  await deps.reserve(requestId);
  const { bytes, duration } = await deps.load(source, req.signal);
  assert(bytes.byteLength > 0 && bytes.byteLength <= MEDIA_ANALYSIS_LIMITS.mediaBytes && Number.isFinite(duration) && duration > 0 && duration <= MEDIA_ANALYSIS_LIMITS.seconds, 422, "Use a video under five minutes and 24 MB for speech analysis.");
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  if (source.source_kind === "project_media") assert(fingerprint === source.media.sha256, 422, "The saved original failed its integrity check. Reselect and save the original again.");
  if ("listing_id" in input) await context.authorizeListing(input.listing_id);
  await deps.authorize(source);
  assert(deps.enabled() && await deps.writable(), 403, "Speech analysis access changed before it started.");
  const finalRoute = await deps.route();
  assert(finalRoute && finalRoute.route_id === route.route_id && finalRoute.model === route.model && finalRoute.provider === route.provider && finalRoute.unit_cents === route.unit_cents && finalRoute.unit === route.unit, 503, "The speech service changed. Submit a new request when available.");
  req.signal.throwIfAborted();
  let returned = false;
  try {
    const raw = await deps.transcribe(finalRoute, bytes, req.signal);
    returned = true;
    const result = analysisOutput(raw, source, fingerprint, duration);
    // Never return transcript data after source deletion, likeness revocation,
    // membership removal, or account deletion during the provider request.
    if ("listing_id" in input) await context.authorizeListing(input.listing_id);
    await deps.authorize(source);
    assert(await deps.writable(), 403, "Your access changed while analyzing this video.");
    req.signal.throwIfAborted();
    return json(result, 200, { "Cache-Control": "private, no-store" });
  } finally {
    // Cancellation cannot retract an accepted paid request. Keep its estimate
    // once and never automatically resubmit, even if the result was not usable.
    await deps.record(finalRoute, Math.ceil(duration), returned ? "returned" : "uncertain");
  }
}
