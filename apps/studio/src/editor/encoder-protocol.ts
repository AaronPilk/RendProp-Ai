import type {EncoderConfig, NormalizedEncoderConfig} from "./export-plan";

export const VIDEO_CREDITS = 2, AUDIO_CREDITS = 8, PCM_STRIDE = 1024;
export const PCM_BYTES = PCM_STRIDE * 2 * 4;
export const FPS = 30, RATE = 48000;
export type EncodedPacket = Readonly<{timestamp: number; duration: number; bytes: number}>;
export class EncoderUnsupportedError extends Error {
  readonly code = "ENCODER_UNSUPPORTED";
  constructor(message = "This browser cannot encode this video configuration.") {
    super(message); this.name = "EncoderUnsupportedError";
  }
}
export function isEncoderUnsupportedError(error: unknown): error is EncoderUnsupportedError {
  return error instanceof EncoderUnsupportedError;
}
export function requireIdentity(runId: unknown, revision: unknown): void {
  if (typeof runId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(runId) ||
      typeof revision !== "string" || revision.length < 1 || revision.length > 128)
    throw new Error("Invalid encoder run identity.");
}
export function requireEnvelope(row: unknown, runId: string, revision: string): void {
  requireIdentity(runId, revision);
  if (!row || typeof row !== "object" ||
      (row as {runId?: unknown}).runId !== runId || (row as {revision?: unknown}).revision !== revision)
    throw new Error("Stale or invalid encoder run identity.");
}
export function normalizeConfig(value: EncoderConfig): NormalizedEncoderConfig {
  if (!value || !Number.isSafeInteger(value.durationMicroseconds) || value.durationMicroseconds < 1 ||
      value.durationMicroseconds > 180e6 || !Number.isSafeInteger(value.frames) || value.frames < 1 ||
      value.frames > 5400 || value.frames !== Math.ceil(value.durationMicroseconds * FPS / 1e6) ||
      ![[1280,720],[720,1280],[960,960]].some(([w,h]) => value.width === w && value.height === h) ||
      typeof value.withAudio !== "boolean" || !Number.isSafeInteger(value.audioFrames) ||
      !Array.isArray(value.windowFrameCounts))
    throw new Error("The encoder configuration is outside Studio export bounds.");
  const counts = Array.from(value.windowFrameCounts);
  if (value.withAudio) {
    // The two independent rounding operations can differ by at most .524 PCM
    // samples. Do not derive PCM length from the rounded video microseconds.
    if (value.audioFrames < 1 || value.audioFrames > 180 * RATE || counts.length < 1 || counts.length > 12 ||
        Math.abs(value.audioFrames * 1e6 - value.durationMicroseconds * RATE) > 524000 ||
        !counts.every(n => Number.isSafeInteger(n) && n > 0 && n <= value.audioFrames) ||
        counts.reduce((sum,n) => sum+n, 0) !== value.audioFrames)
      throw new Error("The PCM window plan is invalid.");
  } else if (value.audioFrames !== 0 || counts.length !== 0) {
    throw new Error("A silent export cannot admit PCM samples.");
  }
  return Object.freeze({width: value.width, height: value.height, frames: value.frames,
    durationMicroseconds: value.durationMicroseconds, withAudio: value.withAudio,
    audioFrames: value.audioFrames, windowFrameCounts: Object.freeze(counts),
    frameRate: FPS, sampleRate: RATE, channels: 2});
}
export function videoTiming(config: EncoderConfig, index: number): {timestamp: number; duration: number} {
  if (!Number.isSafeInteger(index) || index < 0 || index >= config.frames)
    throw new Error("Video frame index is outside the export plan.");
  const timestamp = Math.round(index * 1e6 / FPS);
  const end = Math.min(config.durationMicroseconds, Math.round((index + 1) * 1e6 / FPS));
  if (end <= timestamp) throw new Error("The final video frame has no duration.");
  return {timestamp, duration: end - timestamp};
}
export function verifyEncodedPackets(config: NormalizedEncoderConfig, encoded: readonly EncodedPacket[]): void {
  if (!Array.isArray(encoded) || encoded.length !== config.frames)
    throw new Error("Encoded video packet metadata is incomplete.");
  for (let index=0; index<encoded.length; index++) {
    const packet=encoded[index]!, expected=videoTiming(config,index);
    if (!Number.isFinite(packet.timestamp) || !Number.isFinite(packet.duration) || packet.duration <= 0 ||
        Math.abs(packet.timestamp * 1e6 - expected.timestamp) > 1 ||
        Math.abs(packet.duration * 1e6 - expected.duration) > 1 ||
        !Number.isSafeInteger(packet.bytes) || packet.bytes < 1)
      throw new Error("Actual encoded packet timing changed.");
  }
}
export function createAdmission(config: NormalizedEncoderConfig) {
  const pending = {video: new Set<number>(), audio: new Set<number>()};
  let videoCount=0, audioCount=0, audioFrames=0, videoAck=0, audioAck=0, ended=false;
  let audioWindowIndex=0, audioWindowEnd=config.windowFrameCounts[0] ?? 0;
  const active=()=>{if(ended)throw new Error("Encoder input has ended.");};
  return {
    video(sequence: number, timestamp: number, duration: number | null) {
      active(); const expected=videoTiming(config,videoCount);
      if (sequence!==videoCount || pending.video.size>=VIDEO_CREDITS ||
          timestamp!==expected.timestamp || duration!==expected.duration)
        throw new Error("Video sequence, timestamp or credit changed.");
      pending.video.add(sequence); videoCount++;
    },
    audio(sequence: number, startFrame: number, frameCount: number, stride: number, bytes: number) {
      active();
      if (!config.withAudio || audioFrames>=config.audioFrames || sequence!==audioCount || startFrame!==audioFrames ||
          frameCount!==Math.min(PCM_STRIDE,audioWindowEnd-audioFrames) || frameCount<1 ||
          stride!==PCM_STRIDE || bytes!==PCM_BYTES || pending.audio.size>=AUDIO_CREDITS)
        throw new Error("PCM sequence, window, layout or credit changed.");
      pending.audio.add(sequence); audioCount++; audioFrames+=frameCount;
      if (audioFrames===audioWindowEnd) {
        audioWindowIndex++;
        if (audioWindowIndex<config.windowFrameCounts.length) audioWindowEnd+=config.windowFrameCounts[audioWindowIndex]!;
      }
    },
    ack(track: "video" | "audio", sequence: number) {
      const expected=track==="video"?videoAck:track==="audio"?audioAck:-1;
      if (expected<0 || sequence!==expected || !pending[track].delete(sequence))
        throw new Error("Duplicate, reordered or unknown encoder acknowledgement.");
      if(track==="video")videoAck++;else audioAck++;
    },
    end() {
      active();
      if(videoCount!==config.frames || audioFrames!==config.audioFrames || pending.video.size || pending.audio.size)
        throw new Error("Encoder input is incomplete or still in flight.");
      ended=true;
    },
    stats:()=>({videoCount,audioCount,audioFrames,videoPending:pending.video.size,audioPending:pending.audio.size,
      videoAck,audioAck,audioWindowIndex,audioWindowEnd,ended}),
  };
}
