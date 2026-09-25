import {FINISHING_LIMITS, validateAudioSource, type AudioSourceRef} from "./finishing";
import {awaitMediaOperation, throwIfAborted, waitForEvent} from "./media";

export type LocalMusic = {file: File; source: AudioSourceRef; url: string};
export function musicMime(file: Pick<File, "type" | "name">): string {
  if (["audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/wave", "audio/ogg", "audio/webm"].includes(file.type)) return file.type;
  if (!file.type) {
    const extension = file.name.split(".").at(-1)?.toLowerCase();
    const inferred: Record<string, string> = {mp3: "audio/mpeg", m4a: "audio/mp4", wav: "audio/wav", ogg: "audio/ogg", webm: "audio/webm"};
    if (extension && inferred[extension]) return inferred[extension];
  }
  throw new Error("Choose MP3, M4A, WAV, Ogg or WebM audio you have permission to use.");
}
export async function decodeMusic(blob: Blob, context: AudioContext, signal: AbortSignal): Promise<AudioBuffer> {
  if (!blob.size || blob.size > FINISHING_LIMITS.audioBytes) throw new Error("Music must be under 16 MiB.");
  throwIfAborted(signal);
  // Read container duration before allocating decoded PCM. A small compressed
  // file can otherwise expand into hours of audio despite the byte ceiling.
  const url = URL.createObjectURL(blob), probe = new Audio(); probe.preload = "metadata";
  try {
    const ready = waitForEvent(probe, "loadedmetadata", signal); probe.src = url; probe.load(); await ready;
    if (!Number.isFinite(probe.duration) || probe.duration < .5 || probe.duration > FINISHING_LIMITS.audioSeconds) throw new Error("Choose a music excerpt up to three minutes.");
  } finally {probe.removeAttribute("src"); probe.load(); URL.revokeObjectURL(url);}
  throwIfAborted(signal);
  const buffer = await awaitMediaOperation(context.decodeAudioData(await blob.arrayBuffer()), signal, "Decoding music");
  if (!Number.isFinite(buffer.duration) || buffer.duration < .5 || buffer.duration > FINISHING_LIMITS.audioSeconds || buffer.numberOfChannels > 2 || buffer.sampleRate > 48000) throw new Error("Use a music excerpt up to three minutes, with mono or stereo sound at 48 kHz or below.");
  return buffer;
}
export async function inspectMusic(file: File, signal: AbortSignal, expected?: AudioSourceRef): Promise<LocalMusic> {
  const mime = musicMime(file);
  if (!file.size || file.size > FINISHING_LIMITS.audioBytes) throw new Error("Music must be under 16 MiB. Choose a short licensed excerpt.");
  if (typeof AudioContext === "undefined") throw new Error("Music needs a browser with Web Audio support.");
  throwIfAborted(signal);
  const context = new AudioContext({sampleRate: 48000});
  try {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer()); throwIfAborted(signal);
    const sha256 = Array.from(new Uint8Array(digest), value => value.toString(16).padStart(2, "0")).join("");
    if (expected && (expected.sha256 !== sha256 || expected.size !== file.size)) throw new Error("Reselect the exact original music file; its fingerprint must match the saved edit.");
    const buffer = await decodeMusic(file, context, signal); throwIfAborted(signal);
    const source = validateAudioSource({name: file.name, size: file.size, lastModified: file.lastModified, sha256, duration: buffer.duration, mime});
    if (expected && Math.abs(expected.duration - source.duration) > .05) throw new Error("The music duration does not match the saved edit.");
    return {file, source: expected ?? source, url: URL.createObjectURL(file)};
  } finally {await context.close();}
}

/** Estimate a regular pulse from onset energy. A proposal still needs human review. */
export function detectBeatGrid(samples: Float32Array, sampleRate: number): {bpm: number; firstBeat: number; confidence: number} {
  if (!samples.length || sampleRate < 8000 || sampleRate > 96000) throw new Error("Music analysis could not read this audio.");
  const hop = Math.max(1, Math.round(sampleRate / 100)), envelope: number[] = [];
  let previous = 0;
  for (let offset = 0; offset < samples.length; offset += hop) {
    let energy = 0; const length = Math.min(hop, samples.length - offset);
    for (let i = 0; i < length; i++) energy += samples[offset + i] ** 2;
    energy = Math.sqrt(energy / length); envelope.push(Math.max(0, energy - previous)); previous = energy;
  }
  const power = envelope.reduce((sum, value) => sum + value ** 2, 0);
  if (power < .0001 || envelope.length < 200) throw new Error("No clear beat was found. Enter the song’s tempo and first beat manually.");
  let bestLag = 0, score = 0;
  for (let lag = 25; lag <= 150 && lag < envelope.length / 2; lag++) {
    let sum = 0;
    for (let i = lag; i < envelope.length; i++) sum += envelope[i] * envelope[i - lag];
    sum /= power;
    if (sum > score) {score = sum; bestLag = lag;}
  }
  if (!bestLag || score < .08) throw new Error("No steady beat was found. Enter the song’s tempo and first beat manually.");
  let phase = 0, strength = 0;
  for (let start = 0; start < bestLag; start++) {
    let sum = 0;
    for (let i = start; i < envelope.length; i += bestLag) sum += envelope[i];
    if (sum > strength) {phase = start; strength = sum;}
  }
  return {bpm: Math.round(6000 / bestLag * 10) / 10, firstBeat: phase / 100, confidence: Math.min(1, score)};
}
export async function analyzeMusic(file: File, signal: AbortSignal): Promise<ReturnType<typeof detectBeatGrid>> {
  const context = new AudioContext({sampleRate: 48000});
  try {const buffer = await decodeMusic(file, context, signal); throwIfAborted(signal); return detectBeatGrid(buffer.getChannelData(0), buffer.sampleRate);}
  finally {await context.close();}
}
