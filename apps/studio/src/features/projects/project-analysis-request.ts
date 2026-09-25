import type { StudioServices } from "../../data";
import type { EditClip } from "../../editor/model";

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
function checkClip(clip: EditClip) {
  if (clip.source.kind !== "video") throw new Error("Choose a video recording with speech.");
  if (clip.source.size > 24_000_000 || clip.source.duration > 300) throw new Error("Speech analysis needs an MP4 or MOV copy under 24 MB and five minutes. You can also import timed subtitles.");
}
/** This is an identity lookup, not media download. The server independently
 * verifies ownership, every chunk, and the assembled original's full hash. */
export function buildProjectAnalysisRequest(clip: EditClip, raw: unknown): { source_id: string; source_kind: "project_media" } {
  checkClip(clip);
  const media = (raw as { media?: Record<string, unknown> } | null)?.media;
  if (!media || typeof media.id !== "string" || !UUID.test(media.id) || media.complete !== true || media.sha256 !== clip.source.sha256 || media.bytes !== clip.source.size) throw new Error("Save this project and finish uploading its original before transcribing it.");
  if (!["video/mp4", "video/quicktime"].includes(String(media.mime))) throw new Error("Use an MP4 or MOV original for speech analysis, or import timed subtitles.");
  return { source_id: media.id, source_kind: "project_media" };
}
export async function requestProjectAnalysis(services: StudioServices, orgId: string, clip: EditClip, savedProject: boolean, signal: AbortSignal): Promise<unknown> {
  signal.throwIfAborted(); checkClip(clip);
  if (!savedProject) throw new Error("Save this project to your account first. Transcription uses its saved original; it does not upload local files automatically.");
  const capability = await services.api("/functions/v1/studio/media-analysis", { orgId, signal }) as { available?: unknown };
  if (capability.available !== true) throw new Error("Automatic speech captions are not enabled yet. Import an SRT or WebVTT transcript to add reviewed captions now.");
  signal.throwIfAborted();
  const source = await services.api(`/functions/v1/studio/project-media?sha256=${clip.source.sha256}`, { orgId, signal });
  const body = buildProjectAnalysisRequest(clip, source);
  signal.throwIfAborted();
  return services.api("/functions/v1/studio/media-analysis", { orgId, method: "POST", signal, timeoutMs: 150_000, idempotencyKey: crypto.randomUUID(), body });
}
