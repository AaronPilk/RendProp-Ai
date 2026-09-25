import { assert } from "../_shared/http.ts";

const HASH = /^[a-f0-9]{64}$/;
function object(value: unknown): Record<string, unknown> { assert(value && typeof value === "object" && !Array.isArray(value), 400, "The saved sound track is unreadable."); return value as Record<string, unknown>; }
function number(value: unknown, min: number, max: number): number { assert(typeof value === "number" && Number.isFinite(value) && value >= min && value <= max, 400, "The saved sound timing is invalid."); return value; }
function hash(value: unknown): string { assert(typeof value === "string" && HASH.test(value), 400, "The saved sound source has no fingerprint."); return value; }
/** Source text and `reviewed`/`licensed` are user declarations. This validator
 * never upgrades them to verified property facts or a rights certificate. */
export function assertFinishingPayload(raw: unknown): void {
  const draft = object(raw);
  if (draft.music !== undefined) {
    const m = object(draft.music), s = object(m.source);
    hash(s.sha256);
    const size = number(s.size, 1, 16 * 1024 * 1024), date = number(s.lastModified, 0, Number.MAX_SAFE_INTEGER), duration = number(s.duration, .5, 180);
    assert(Number.isSafeInteger(size) && Number.isSafeInteger(date), 400, "The music file metadata is invalid.");
    assert(typeof s.name === "string" && !!s.name.trim() && s.name.length <= 255 && !/[\u0000-\u001f]/.test(s.name), 400, "The music filename is invalid.");
    assert(["audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/wave", "audio/ogg", "audio/webm"].includes(String(s.mime)), 400, "Choose a supported music file.");
    const start = number(m.start, 0, duration - .1), end = number(m.end, start + .1, duration);
    number(m.offset, 0, 180); number(m.volume, 0, 1); number(m.fadeIn, 0, Math.min(10, end - start)); number(m.fadeOut, 0, Math.min(10, end - start));
    assert(m.licensed === true && ["speech", "original", "none"].includes(String(m.ducking)), 400, "Confirm music permission and choose a mixing setting.");
  }
  if (draft.speech !== undefined) {
    assert(Array.isArray(draft.speech) && draft.speech.length <= 12, 400, "Speech captions have too many source tracks.");
    const sources = new Set<string>(); let count = 0;
    for (const value of draft.speech) {
      const track = object(value), sha = hash(track.sourceSha256), duration = number(track.sourceDuration, .5, 300);
      assert(track.reviewed === true && !sources.has(sha), 400, "Review each speech caption source once before saving."); sources.add(sha);
      assert(Array.isArray(track.words) && (count += track.words.length) <= 1500, 400, "Speech captions exceed 1,500 timed words.");
      let previous = 0;
      for (const word of track.words) {
        const w = object(word), start = number(w.start, previous, duration); number(w.end, start + .001, duration); previous = start;
        assert(typeof w.text === "string" && !!w.text.trim() && w.text.length <= 80 && !/[\u0000-\u001f]/.test(w.text), 400, "A speech caption is unreadable or too long.");
      }
      // Orphan tracks may be retained for undo, so a missing current clip does
      // not authorize or fetch a source. Present matching clips must agree.
      if (Array.isArray(draft.clips)) for (const value of draft.clips) {
        const clip = object(value), source = object(clip.source);
        if (source.sha256 === sha) assert(source.kind === "video" && typeof source.duration === "number" && Math.abs(source.duration - duration) <= .1, 400, "Speech captions do not match the original video.");
      }
    }
  }
}
