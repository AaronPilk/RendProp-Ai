import type {EditClip, EditDraft} from "./model";

export const FINISHING_LIMITS = {audioBytes: 16 * 1024 * 1024, audioSeconds: 180, tracks: 12, words: 1500} as const;
export type AudioSourceRef = {name: string; size: number; lastModified: number; sha256: string; duration: number; mime: string};
export type MusicTrack = {source: AudioSourceRef; start: number; end: number; offset: number; volume: number; fadeIn: number; fadeOut: number; ducking: "speech" | "original" | "none"; licensed: true};
export type SpeechWord = {text: string; start: number; end: number};
export type SpeechTrack = {sourceSha256: string; sourceDuration: number; reviewed: true; words: SpeechWord[]};
const object = (value: unknown, label: string): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`Invalid ${label}.`);
  return value as Record<string, unknown>;
};
const number = (value: unknown, minimum: number, maximum: number, label: string) => {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) throw new Error(`Invalid ${label}.`);
  return value;
};
const text = (value: unknown, maximum: number, label: string) => {
  if (typeof value !== "string" || !value.trim() || value.length > maximum || /[\u0000-\u001f]/.test(value)) throw new Error(`Invalid ${label}.`);
  return value;
};
const hash = (value: unknown) => {if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) throw new Error("Missing original media fingerprint."); return value;};
export function validateAudioSource(value: unknown): AudioSourceRef {
  const row = object(value, "music source"), size = number(row.size, 1, FINISHING_LIMITS.audioBytes, "music bytes"), lastModified = number(row.lastModified, 0, Number.MAX_SAFE_INTEGER, "music date");
  if (!Number.isSafeInteger(size) || !Number.isSafeInteger(lastModified)) throw new Error("Invalid music file metadata.");
  const mime = text(row.mime, 100, "music type");
  if (!["audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/wave", "audio/ogg", "audio/webm"].includes(mime)) throw new Error("Choose MP3, M4A, WAV, Ogg or WebM audio.");
  return {name: text(row.name, 255, "music name"), size, lastModified, sha256: hash(row.sha256), duration: number(row.duration, .5, FINISHING_LIMITS.audioSeconds, "music duration"), mime};
}
export function validateMusic(value: unknown): MusicTrack {
  const row = object(value, "music track"), source = validateAudioSource(row.source);
  const start = number(row.start, 0, source.duration - .1, "music start"), end = number(row.end, start + .1, source.duration, "music end");
  if (row.licensed !== true || !["speech", "original", "none"].includes(String(row.ducking))) throw new Error("Confirm permission to use this music and choose its mixing setting.");
  return {source, start, end, offset: number(row.offset, 0, 180, "music timeline start"), volume: number(row.volume, 0, 1, "music volume"), fadeIn: number(row.fadeIn, 0, Math.min(10, end - start), "music fade in"), fadeOut: number(row.fadeOut, 0, Math.min(10, end - start), "music fade out"), ducking: row.ducking as MusicTrack["ducking"], licensed: true};
}
export function validateSpeechWords(value: unknown, duration: number): SpeechWord[] {
  if (!Array.isArray(value) || value.length > FINISHING_LIMITS.words) throw new Error("Speech captions support up to 1,500 timed words.");
  let previous = 0;
  return value.map(item => {
    const row = object(item, "speech word"), start = number(row.start, previous, duration, "speech start"), end = number(row.end, start + .001, duration, "speech end");
    previous = start;
    return {text: text(row.text, 80, "speech text"), start, end};
  });
}
export function validateSpeech(value: unknown): SpeechTrack[] {
  if (!Array.isArray(value) || value.length > FINISHING_LIMITS.tracks) throw new Error("Too many speech caption sources.");
  const hashes = new Set<string>(); let count = 0;
  return value.map(item => {
    const row = object(item, "speech captions"), sourceSha256 = hash(row.sourceSha256), sourceDuration = number(row.sourceDuration, .5, 300, "speech source duration");
    if (row.reviewed !== true || hashes.has(sourceSha256)) throw new Error("Review each original speech transcript before using it.");
    hashes.add(sourceSha256);
    const words = validateSpeechWords(row.words, sourceDuration); count += words.length;
    if (count > FINISHING_LIMITS.words) throw new Error("Speech captions support up to 1,500 timed words in this edit.");
    return {sourceSha256, sourceDuration, reviewed: true, words};
  });
}
export function sourceSpeech(draft: Pick<EditDraft, "speech">, clip: EditClip): SpeechWord[] {
  const track = draft.speech?.find(item => item.sourceSha256 === clip.source.sha256 && Math.abs(item.sourceDuration - clip.source.duration) <= .1);
  return track?.words.filter(word => word.start >= clip.start && word.end <= clip.end) ?? [];
}
export function speechCaption(draft: Pick<EditDraft, "speech">, clip: EditClip, localTime: number): string {
  if (clip.source.kind !== "video") return "";
  const words = sourceSpeech(draft, clip), time = clip.start + localTime * (clip.speed ?? 1);
  const index = words.findIndex(word => time >= word.start && time < word.end);
  if (index < 0) return "";
  return words[index].text;
}
const duration = (clip: EditClip) => (clip.end - clip.start) / (clip.source.kind === "video" ? clip.speed ?? 1 : 1);
export function musicGainAt(draft: EditDraft, clip: EditClip, timelineTime: number, localTime: number, narrationDuration = 0): number {
  const music = draft.music; if (!music) return 0;
  const length = music.end - music.start, elapsed = timelineTime - music.offset;
  const timelineEnd = draft.clips.reduce((sum, item) => sum + duration(item), 0);
  const audibleLength = Math.min(length, timelineEnd - music.offset);
  if (elapsed < 0 || elapsed >= audibleLength) return 0;
  const fade = Math.min(1, music.fadeIn ? elapsed / music.fadeIn : 1, music.fadeOut ? (audibleLength - elapsed) / music.fadeOut : 1);
  const narrationActive = !!draft.narration && timelineTime >= draft.narration.offset && timelineTime < draft.narration.offset + narrationDuration;
  const originalActive = draft.audio === "original" && clip.source.kind === "video";
  const sourceTime = clip.start + localTime * (clip.speed ?? 1);
  const speechActive = originalActive && sourceSpeech(draft, clip).some(word => sourceTime >= word.start - .12 && sourceTime < word.end + .2);
  const duck = music.ducking !== "none" && (narrationActive || (music.ducking === "original" ? originalActive : speechActive));
  return music.volume * Math.max(0, fade) * (duck ? .22 : 1);
}
export type BeatProposal = {draftId: string; revision: number; bpm: number; firstBeat: number; clips: EditClip[]; changes: {clipId: string; before: number; after: number}[]};
/** A reviewable grid, never a silent rewrite. Video is only shortened within its selection. */
export function proposeBeatCuts(draft: EditDraft, bpm: number, firstBeat: number): BeatProposal {
  number(bpm, 40, 240, "tempo"); number(firstBeat, 0, 180, "first beat");
  if (draft.clips.length < 2) throw new Error("Add at least two shots to align their cuts.");
  if (draft.narration || draft.overlays?.length) throw new Error("This edit has timed narration or cutaways. Keep those timings or adjust their tracks before aligning cuts.");
  const beat = 60 / bpm; let cursor = 0;
  const changes: BeatProposal["changes"] = [];
  const clips = draft.clips.map((clip, index) => {
    const before = duration(clip);
    if (index === draft.clips.length - 1) return {...clip};
    const minimum = .5 / (clip.source.kind === "video" ? clip.speed ?? 1 : 1);
    const desired = cursor + before, nearest = firstBeat + Math.round((desired - firstBeat) / beat) * beat;
    let end = nearest;
    if (clip.source.kind === "video" && end > desired + .000001) end -= beat;
    if (end - cursor < minimum || end - cursor > (clip.source.kind === "image" ? 30 : before)) {cursor += before; return {...clip};}
    const after = Number((end - cursor).toFixed(4)); cursor += after;
    if (Math.abs(before - after) > .001) changes.push({clipId: clip.id, before, after});
    return {...clip, end: clip.source.kind === "image" ? after : clip.start + after * (clip.speed ?? 1), transition: "cut" as const};
  });
  if (clips.reduce((sum, clip) => sum + duration(clip), 0) > 180) throw new Error("Aligned cuts would exceed the three-minute edit limit.");
  if (!changes.length) throw new Error("These cuts already fit the grid or cannot move within their selected footage.");
  return {draftId: draft.id, revision: draft.revision, bpm, firstBeat, clips, changes};
}

/** Subtitle files carry timing supplied by the user; they still require review. */
export function parseSubtitleFile(input: string, sourceDuration: number): SpeechWord[] {
  if (new TextEncoder().encode(input).length > 128 * 1024) throw new Error("Subtitle files must be under 128 KiB.");
  const normalized = input.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n").trim();
  const vtt = /^WEBVTT(?:\s|$)/.test(normalized);
  const time = (value: string) => {
    if (!/^(?:\d{1,2}:)?[0-5]\d:[0-5]\d[.,]\d{3}$/.test(value)) throw new Error("A subtitle has an invalid timestamp.");
    const fields = value.replace(",", ".").split(":").map(Number);
    return fields.length === 3 ? fields[0] * 3600 + fields[1] * 60 + fields[2] : fields[0] * 60 + fields[1];
  };
  const words: SpeechWord[] = [];
  let previousEnd = 0;
  for (const block of normalized.split(/\n\s*\n/).filter(Boolean)) {
    if (vtt && /^(?:WEBVTT(?:[^\n]*$)|NOTE(?:[ \t]|\n|$)|STYLE(?:\n|$)|REGION(?:\n|$))/.test(block)) continue;
    const lines = block.trim().split("\n"), index = lines.findIndex(line => /\s-->\s/.test(line));
    if (index < 0 || index > 1 || index === lines.length - 1) throw new Error("Every subtitle needs its original start/end times and spoken text.");
    const match = lines[index].match(/^((?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3})\s+-->\s+((?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3})(?:\s.*)?$/);
    if (!match) throw new Error("A subtitle has an invalid timestamp.");
    const caption = lines.slice(index + 1).join(" ").replace(/<[^>]*>/g, "").trim();
    if (!caption) throw new Error("Every subtitle needs spoken text.");
    const start = time(match[1]), end = time(match[2]);
    if (start < previousEnd) throw new Error("Subtitle cues must not overlap.");
    previousEnd = end;
    // Keep authored cue timing. Do not invent per-word timestamps.
    words.push({text: caption, start, end});
  }
  if (!words.length) throw new Error("No timed subtitles were found. Choose an SRT or WebVTT file for this original clip.");
  return validateSpeechWords(words, sourceDuration);
}

export type SpeechPassage = {start: number; end: number; text: string};
/** Only source-backed, contiguous transcript segments can become a trim proposal. */
export function decodeSpeechPassages(raw: unknown, words: SpeechWord[], duration: number): SpeechPassage[] {
  const value = object(raw, "speech analysis");
  if (value.segments === undefined && value.highlights === undefined) return [];
  if (!Array.isArray(value.segments) || value.segments.length > 1500 || !Array.isArray(value.highlights) || value.highlights.length > 5) throw new Error("Invalid speaking-passage suggestions.");
  const ids = new Set<string>(); let previousEnd = 0;
  const segments = value.segments.map(item => {
    const row = object(item, "speech passage"), id = text(row.id, 100, "passage ID"), start = number(row.start, previousEnd, duration, "passage start"), end = number(row.end, start + .001, duration, "passage end");
    if (ids.has(id)) throw new Error("Duplicate speaking passage."); ids.add(id); previousEnd = end;
    const matching = words.filter(word => word.start >= start && word.end <= end);
    const quote = matching.map(word => word.text).join(" ");
    if (!matching.length || matching[0].start !== start || matching.at(-1)!.end !== end || row.text !== quote || quote.length > 120) throw new Error("A suggested passage is not backed by the original transcript.");
    return {id, start, end, text: quote};
  });
  return value.highlights.map(item => {
    const row = object(item, "speaking suggestion");
    if (!Array.isArray(row.segmentIds) || !row.segmentIds.length || row.segmentIds.length > 6) throw new Error("Choose a bounded speaking passage.");
    const indices = row.segmentIds.map(id => segments.findIndex(segment => segment.id === id));
    if (indices.some((index, i) => index < 0 || i > 0 && index !== indices[i - 1] + 1)) throw new Error("Suggested speech must be consecutive in the original video.");
    const first = segments[indices[0]], last = segments[indices.at(-1)!];
    if (row.start !== first.start || row.end !== last.end) throw new Error("The suggested passage timing changed.");
    return {start: first.start, end: last.end, text: indices.map(index => segments[index].text).join(" ")};
  });
}
export function useSpeechPassage(draft: EditDraft, clipId: string, passage: SpeechPassage): EditClip[] {
  const clip = draft.clips.find(item => item.id === clipId);
  if (!clip || clip.source.kind !== "video") throw new Error("Select the original speaking video.");
  if (draft.narration || draft.overlays?.length) throw new Error("This edit has timed narration or cutaways. Adjust those tracks before replacing a speaking passage.");
  const start = number(passage.start, 0, clip.source.duration, "passage start"), end = number(passage.end, start + .5, clip.source.duration, "passage end");
  const clips = draft.clips.map(item => item.id === clipId ? {...item, start, end} : item);
  if (clips.reduce((sum, item) => sum + duration(item), 0) > 180) throw new Error("This passage would exceed the three-minute edit limit.");
  return clips;
}
