import {decodeMusic} from "./music";
import {musicGainAt} from "./finishing";
import {createExportPCMCapture} from "./export-pcm";
import {sendOwnedPCMBlock} from "./export-pcm-ownership";
import {disjointMusicCurve} from "./export-audio-schedule";
import {primeExportAudioSource} from "./export-audio-prime";
import {OFFLINE_PCM_CAP, originalDuckTiming, pcmWindowMode,
  windowTrackSlice} from "./export-audio-route";
import type {ExportAudioBootstrap} from "./export-audio-bootstrap";
import type {ExportPlan, ExportWindow} from "./export-plan";
import {
  assertCurrentRevision, clipDuration, type EditClip, type EditDraft,
} from "./model";
import {
  awaitMediaOperation, decodeMedia, seekMedia, throwIfAborted,
  type DecodedMedia, type LocalMedia,
} from "./media";

const RATE = 48_000;
const BLOCK = 1024;
const CHANNELS = 2;
const ORIGINAL_DECODE_CAP = 32 * 1024 * 1024;
const MAX_ORIGINAL_AUDIO_LOSS_SECONDS = 2 / 30;

type AudioEncoder = {
  addAudio(buffer: ArrayBuffer, startFrame: number, frameCount: number): Promise<ArrayBuffer>;
};
type AudioOptions = {
  begun: ExportAudioBootstrap;
  draft: EditDraft;
  plan: ExportPlan;
  media: Map<string, LocalMedia>;
  narrationBlob?: Blob;
  musicBlob?: Blob;
  encoder: AudioEncoder;
  signal: AbortSignal;
  currentDraft(): EditDraft;
  fail(error: Error): void;
  onProgress(fraction: number): void;
};
type Tracks = {voice?: AudioBuffer; music?: AudioBuffer};
type Prepared = {media: DecodedMedia; originalBuffer?: AudioBuffer} | {error: unknown};
type Pending = {settled: Promise<Prepared>; result?: Prepared};
const asError = (value: unknown): Error =>
  value instanceof Error ? value : new Error(String(value));

export function requiresLivePCM(draft: EditDraft, plan: ExportPlan): boolean {
  const originalAudio = draft.audio === "original" &&
    draft.clips.some(clip => clip.source.kind === "video");
  return originalAudio ||
    plan.config.audioFrames * CHANNELS * 4 > OFFLINE_PCM_CAP ||
    typeof OfflineAudioContext === "undefined";
}

function requireCurrent(options: AudioOptions): void {
  throwIfAborted(options.signal);
  assertCurrentRevision(options.draft, options.currentDraft(), options.signal);
  if (document.hidden)
    throw new Error("The tab was hidden during export. No download was created.");
}

async function loadTracks(options: AudioOptions): Promise<Tracks> {
  const {draft, begun, signal} = options;
  const audio = begun.context;
  const tracks: Tracks = {};
  if (draft.narration) {
    const blob = options.narrationBlob;
    if (!blob?.size)
      throw new Error("Restore the selected narration before exporting.");
    const bytes = await awaitMediaOperation(blob.arrayBuffer(), signal,
      "Reading narration");
    tracks.voice = await awaitMediaOperation(audio.decodeAudioData(bytes),
      signal, "Decoding narration");
    if (!Number.isFinite(tracks.voice.duration) || tracks.voice.duration <= 0 ||
        tracks.voice.duration > 300 || tracks.voice.numberOfChannels > 2 ||
        tracks.voice.sampleRate > 96_000)
      throw new Error("The saved narration has an invalid duration.");
  }
  if (draft.music) {
    const blob = options.musicBlob;
    if (!blob?.size || blob.size !== draft.music.source.size)
      throw new Error("Restore the selected music before exporting.");
    const bytes = await awaitMediaOperation(blob.arrayBuffer(), signal,
      "Reading music");
    const digest = await awaitMediaOperation(crypto.subtle.digest("SHA-256", bytes),
      signal, "Verifying music");
    const hash = Array.from(new Uint8Array(digest), byte =>
      byte.toString(16).padStart(2, "0")).join("");
    if (hash !== draft.music.source.sha256)
      throw new Error("The music file does not match this saved edit.");
    tracks.music = await decodeMusic(blob, audio, signal);
    if (Math.abs(tracks.music.duration - draft.music.source.duration) > .05)
      throw new Error("The music duration changed.");
  }
  requireCurrent(options);
  return tracks;
}

/** Shipping's four-target-per-frame, 25 ms smoothed music curve. */
export function exportMusicEnvelope(draft: EditDraft, clip: EditClip,
  elapsedBefore: number, duration: number, narrationDuration = 0): Float32Array {
  const points = Math.ceil(duration * 120);
  if (!Number.isSafeInteger(points) || points < 1 || points + 1 > 21_601)
    throw new Error("The music curve exceeded its limit. No download was created.");
  const values = new Float32Array(points + 1);
  let position = 0;
  let target = musicGainAt(draft, clip, elapsedBefore, 0, narrationDuration);
  let value = target;
  let nextTarget = 1 / 30;
  values[0] = value;
  for (let index = 1; index <= points; index++) {
    const end = duration * index / points;
    while (nextTarget < end) {
      value = target + (value - target) *
        Math.exp(-(nextTarget - position) / .025);
      position = nextTarget;
      target = musicGainAt(draft, clip, elapsedBefore + position,
        position, narrationDuration);
      nextTarget += 1 / 30;
    }
    value = target + (value - target) *
      Math.exp(-(end - position) / .025);
    position = end;
    values[index] = value;
  }
  return values;
}

/** Photo/muted-source mixes can render at full offline speed with a finite cap. */
async function captureOffline(options: AudioOptions, tracks: Tracks): Promise<void> {
  const {draft, plan, encoder, signal} = options;
  const totalFrames = plan.config.audioFrames;
  const offline = new OfflineAudioContext(CHANNELS, totalFrames, RATE);
  const started: AudioBufferSourceNode[] = [];
  try {
    if (draft.narration && tracks.voice) {
      const source = offline.createBufferSource();
      const gain = offline.createGain();
      source.buffer = tracks.voice;
      gain.gain.value = draft.narration.volume;
      source.connect(gain); gain.connect(offline.destination);
      if (draft.narration.offset < plan.duration) {
        source.start(draft.narration.offset, 0,
          Math.min(tracks.voice.duration, plan.duration - draft.narration.offset));
        started.push(source);
      }
    }
    if (draft.music && tracks.music) {
      const music = draft.music;
      const source = offline.createBufferSource();
      const gain = offline.createGain();
      source.buffer = tracks.music;
      source.connect(gain); gain.connect(offline.destination);
      const length = Math.min(music.end - music.start,
        plan.duration - music.offset);
      if (length > 0) {
        source.start(music.offset, music.start, length);
        started.push(source);
      }
      for (const window of plan.windows) {
        const clip = draft.clips[window.index]!;
        const {startSeconds, durationSeconds} = disjointMusicCurve(
          window.startFrame, window.frameCount);
        gain.gain.setValueCurveAtTime(exportMusicEnvelope(draft, clip,
          window.startSeconds, durationSeconds, tracks.voice?.duration),
        startSeconds, durationSeconds);
      }
    }
    const rendered = await awaitMediaOperation(offline.startRendering(), signal,
      "Rendering the audio mix", Math.max(15_000, plan.duration * 1000));
    requireCurrent(options);
    if (rendered.sampleRate !== RATE || rendered.numberOfChannels !== CHANNELS ||
        rendered.length !== totalFrames)
      throw new Error("The rendered audio length changed. No download was created.");
    const left = rendered.getChannelData(0);
    const right = rendered.getChannelData(1);
    // Each AAC input block ends within its canonical clip window. A global
    // 1024-frame loop could cross a fractional clip boundary and lose samples.
    for (const window of plan.windows) {
      for (let offset = 0; offset < window.frameCount; offset += BLOCK) {
        requireCurrent(options);
        const start = window.startFrame + offset;
        const count = Math.min(BLOCK, window.frameCount - offset);
        const data = new Float32Array(CHANNELS * BLOCK);
        data.set(left.subarray(start, start + count), 0);
        data.set(right.subarray(start, start + count), BLOCK);
        for (let channel = 0; channel < CHANNELS; channel++)
          for (let sample = 0; sample < count; sample++)
            if (!Number.isFinite(data[channel * BLOCK + sample]))
              throw new Error("The rendered audio contains an invalid sample. No download was created.");
        await sendOwnedPCMBlock(encoder, data.buffer, start, count);
        if (offset % (BLOCK * 16) === 0)
          options.onProgress(Math.min(.45, (start + count) / totalFrames * .45));
      }
    }
  } finally {
    for (const source of started) {
      try {source.stop();} catch { /* source already ended */ }
      source.disconnect();
    }
  }
}

/** Render one canonical window. Neither the wall clock nor the worklet is
 * involved, and the AAC input still starts at the window's global frame. */
async function captureOfflineWindow(options: AudioOptions, tracks: Tracks,
  clip: EditClip, window: ExportWindow, originalBuffer?: AudioBuffer): Promise<void> {
  const {draft, encoder, signal} = options;
  if (window.frameCount < 1 || window.frameCount * CHANNELS * 4 > OFFLINE_PCM_CAP ||
      typeof OfflineAudioContext === "undefined")
    throw new Error("The offline audio window exceeded its limit. No download was created.");
  const offline = new OfflineAudioContext(CHANNELS, window.frameCount, RATE);
  const duration = window.frameCount / RATE;
  const pcmStart = window.startFrame / RATE;
  const started: AudioBufferSourceNode[] = [];
  const gains: GainNode[] = [];
  try {
    if (originalBuffer) {
      const source = offline.createBufferSource();
      const gain = offline.createGain();
      gains.push(gain);
      source.buffer = originalBuffer;
      source.connect(gain); gain.connect(offline.destination);
      const duck = originalDuckTiming(pcmStart, duration,
        draft.narration?.offset, tracks.voice?.duration);
      gain.gain.setValueAtTime(duck.initial, 0);
      if (duck.duckAt !== undefined)
        gain.gain.setTargetAtTime(.22, duck.duckAt, .025);
      if (duck.recoverAt !== undefined)
        gain.gain.setTargetAtTime(1, duck.recoverAt, .025);
      started.push(source);
      source.start(0, clip.start, clip.end - clip.start);
    }
    if (draft.narration && tracks.voice) {
      const slice = windowTrackSlice(pcmStart, duration,
        draft.narration.offset, 0, tracks.voice.duration);
      if (slice) {
        const source = offline.createBufferSource();
        const gain = offline.createGain();
        gains.push(gain);
        source.buffer = tracks.voice;
        gain.gain.value = draft.narration.volume;
        source.connect(gain); gain.connect(offline.destination);
        started.push(source);
        source.start(slice.delay, slice.sourceOffset);
      }
    }
    if (draft.music && tracks.music) {
      const slice = windowTrackSlice(pcmStart, duration,
        draft.music.offset, draft.music.start, draft.music.end);
      if (slice) {
        const source = offline.createBufferSource();
        const gain = offline.createGain();
        gains.push(gain);
        source.buffer = tracks.music;
        gain.gain.setValueCurveAtTime(exportMusicEnvelope(draft, clip,
          window.startSeconds, duration, tracks.voice?.duration), 0, duration);
        source.connect(gain); gain.connect(offline.destination);
        started.push(source);
        source.start(slice.delay, slice.sourceOffset, slice.duration);
      }
    }
    const rendered = await awaitMediaOperation(offline.startRendering(), signal,
      "Rendering the audio mix", Math.max(15_000, duration * 1000));
    requireCurrent(options);
    if (rendered.sampleRate !== RATE || rendered.numberOfChannels !== CHANNELS ||
        rendered.length !== window.frameCount)
      throw new Error("The rendered audio length changed. No download was created.");
    const left = rendered.getChannelData(0);
    const right = rendered.getChannelData(1);
    for (let offset = 0; offset < window.frameCount; offset += BLOCK) {
      requireCurrent(options);
      const count = Math.min(BLOCK, window.frameCount - offset);
      const data = new Float32Array(CHANNELS * BLOCK);
      data.set(left.subarray(offset, offset + count), 0);
      data.set(right.subarray(offset, offset + count), BLOCK);
      for (let channel = 0; channel < CHANNELS; channel++)
        for (let sample = 0; sample < count; sample++)
          if (!Number.isFinite(data[channel * BLOCK + sample]))
            throw new Error("The rendered audio contains an invalid sample. No download was created.");
      await sendOwnedPCMBlock(encoder, data.buffer, window.startFrame + offset, count);
    }
  } finally {
    for (const source of started) {
      try {source.stop();} catch { /* source already ended */ }
      source.disconnect();
    }
    for (const gain of gains) gain.disconnect();
  }
}

async function captureHybrid(options: AudioOptions, tracks: Tracks): Promise<void> {
  const {draft, media, plan, begun, signal} = options;
  const audio = begun.context;
  const originalAudio = draft.audio === "original" &&
    draft.clips.some(clip => clip.source.kind === "video");
  const prepare = (clip: EditClip): Pending => {
    const pending: Pending = {settled: undefined!};
    pending.settled = (async (): Promise<Prepared> => {
      const local = media.get(clip.id);
      if (!local || local.source.sha256 !== clip.source.sha256)
        throw new Error(`Reselect ${clip.source.name} before exporting.`);
      const ready = await decodeMedia(local.url, clip.source.kind, signal);
      try {
        let originalBuffer: AudioBuffer | undefined;
        if (ready.element instanceof HTMLVideoElement) {
          await seekMedia(ready.element, clip.start, signal);
          ready.element.playbackRate = clip.speed ?? 1;
          if (originalAudio && (clip.speed ?? 1) === 1 &&
              clip.source.duration * 96_000 * 2 * 4 <= ORIGINAL_DECODE_CAP) {
            try {
              const bytes = await awaitMediaOperation(local.file.arrayBuffer(),
                signal, "Reading original audio");
              const buffer = await awaitMediaOperation(audio.decodeAudioData(bytes),
                signal, "Decoding original audio");
              if (Number.isFinite(buffer.duration) && buffer.duration > 0 &&
                  buffer.duration >= clip.end - .05 &&
                  buffer.duration <= clip.source.duration + .1 &&
                  buffer.numberOfChannels <= 2 && buffer.sampleRate <= 96_000 &&
                  buffer.length * buffer.numberOfChannels * 4 <= ORIGINAL_DECODE_CAP)
                originalBuffer = buffer;
            } catch {throwIfAborted(signal); /* unsupported decode uses live source */}
          }
        }
        throwIfAborted(signal);
        return {media: ready, originalBuffer};
      } catch (error) {ready.dispose(); throw error;}
    })().then(result => (pending.result = result),
      error => (pending.result = {error}));
    return pending;
  };
  let prepared: Pending | undefined;
  let decoded: DecodedMedia | undefined;
  try {
    prepared = prepare(draft.clips[0]!);
    await prepared.settled;
    for (const [index, clip] of draft.clips.entries()) {
      requireCurrent(options);
      if (!prepared?.result)
        throw new Error("The next audio source was not ready. No download was created.");
      if ("error" in prepared.result) throw prepared.result.error;
      decoded = prepared.result.media;
      const originalBuffer = prepared.result.originalBuffer;
      prepared = undefined;
      if (draft.clips[index + 1]) {
        prepared = prepare(draft.clips[index + 1]!);
        if (index === 0) {
          await prepared.settled;
          if (prepared.result && "error" in prepared.result)
            throw prepared.result.error;
        }
      }
      const window = plan.windows[index];
      if (!window || window.index !== index || window.clipId !== clip.id ||
          window.frameCount < 1)
        throw new Error("The audio window plan changed. No download was created.");
      const duration = window.frameCount / RATE;
      const pcmStart = window.startFrame / RATE;
      const video = decoded.element instanceof HTMLVideoElement ? decoded.element : undefined;
      if (pcmWindowMode(draft, clip, window, Boolean(originalBuffer),
        typeof OfflineAudioContext !== "undefined") === "offline") {
        try {
          await captureOfflineWindow(options, tracks, clip, window, originalBuffer);
          options.onProgress(Math.min(.45,
            (window.startFrame + window.frameCount) / plan.config.audioFrames * .45));
        } finally {
          decoded?.dispose();
          decoded = undefined;
        }
        if (prepared && !prepared.result) await prepared.settled;
        continue;
      }
      let session: Awaited<ReturnType<typeof createExportPCMCapture>> | undefined;
      let voiceGain: GainNode | undefined;
      let musicGain: GainNode | undefined;
      let originalGain: GainNode | undefined;
      let elementSource: MediaElementAudioSourceNode | undefined;
      let bufferedOriginal: AudioBufferSourceNode | undefined;
      let voiceSource: AudioBufferSourceNode | undefined;
      let musicSource: AudioBufferSourceNode | undefined;
      let played: Promise<void> | undefined;
      try {
        // A live capture is owned only by this actual source window. Its wire
        // index/base remain the canonical global plan values, even when an
        // offline window preceded it or follows it.
        session = await createExportPCMCapture({begun, encoder: options.encoder,
          signal, initialIndex: index, initialBase: window.startFrame,
          requireCurrent: () => requireCurrent(options), fail: options.fail});
        voiceGain = tracks.voice ? audio.createGain() : undefined;
        if (voiceGain) {
          voiceGain.gain.value = draft.narration!.volume;
          voiceGain.connect(session.bus);
        }
        musicGain = tracks.music ? audio.createGain() : undefined;
        if (musicGain) {
          musicGain.gain.value = 0;
          musicGain.connect(session.bus);
        }
        if (video && originalAudio) {
          originalGain = audio.createGain();
          originalGain.gain.value = originalBuffer ? 1 : 0;
          originalGain.connect(session.bus);
          if (originalBuffer) {
            bufferedOriginal = audio.createBufferSource();
            bufferedOriginal.buffer = originalBuffer;
            bufferedOriginal.connect(originalGain);
            video.muted = true;
          } else {
            elementSource = audio.createMediaElementSource(video);
            elementSource.connect(originalGain);
            video.muted = false;
            video.volume = 1;
            if ((clip.speed ?? 1) !== 1 && !video.preservesPitch)
              throw new Error("Pitch-preserving original audio is unavailable. No download was created.");
            // Previous windows are drained and the tap is disarmed here. The
            // same element/source is retained for the real capture window.
            await primeExportAudioSource(video, clip.start, clip.end,
              clip.speed ?? 1, signal, () => requireCurrent(options));
          }
        }
        const musicEnvelope = musicGain ? exportMusicEnvelope(draft, clip,
          window.startSeconds, duration, tracks.voice?.duration) : undefined;
        let mediaClockStart: number | undefined;
        let lossReadings = 0;
        let lastVideoTime = video?.currentTime ?? 0;
        let lastAdvance = performance.now();
        await session.captureWindow({index, outputBase: window.startFrame,
          frameCount: window.frameCount,
          startAt(origin) {
            requireCurrent(options);
            if (originalGain) {
              const duck = originalDuckTiming(pcmStart, duration,
                draft.narration?.offset, tracks.voice?.duration);
              originalGain.gain.setValueAtTime(duck.initial, origin);
              if (duck.duckAt !== undefined)
                originalGain.gain.setTargetAtTime(.22, origin + duck.duckAt, .025);
              if (duck.recoverAt !== undefined)
                originalGain.gain.setTargetAtTime(1, origin + duck.recoverAt, .025);
            }
            if (musicGain && musicEnvelope) {
              musicGain.gain.cancelScheduledValues(0);
              musicGain.gain.setValueCurveAtTime(musicEnvelope, origin, duration);
            }
            if (bufferedOriginal) bufferedOriginal.start(origin,
              clip.start, clip.end - clip.start);
            if (draft.narration && tracks.voice && voiceGain) {
              const slice = windowTrackSlice(pcmStart, duration,
                draft.narration.offset, 0, tracks.voice.duration);
              if (slice) {
                voiceSource = audio.createBufferSource();
                voiceSource.buffer = tracks.voice;
                voiceSource.connect(voiceGain);
                voiceSource.start(origin + slice.delay, slice.sourceOffset);
              }
            }
            if (draft.music && tracks.music && musicGain) {
              const slice = windowTrackSlice(pcmStart, duration,
                draft.music.offset, draft.music.start, draft.music.end);
              if (slice) {
                musicSource = audio.createBufferSource();
                musicSource.buffer = tracks.music;
                musicSource.connect(musicGain);
                musicSource.start(origin + slice.delay,
                  slice.sourceOffset, slice.duration);
              }
            }
          },
          async watch(origin, waitTo) {
            await waitTo(0);
            if (elementSource && video) {
              // The captured PCM window already began at origin. Account for
              // time spent inside play() and delayed source progress; a late
              // promise alone does not move this fixed sound origin.
              mediaClockStart = origin;
              played = video.play();
              void played.catch(error => options.fail(asError(error)));
            }
            while (audio.currentTime < origin + duration) {
              await waitTo(Math.min(duration,
                Math.max(0, audio.currentTime - origin + 1 / 30)));
              const now = performance.now();
              if (elementSource && video && video.currentTime > lastVideoTime + .001) {
                lastVideoTime = video.currentTime;
                lastAdvance = now;
              }
              if (elementSource && video && now - lastAdvance > 10_000)
                throw new Error("Video playback stalled during export. No download was created.");
              if (elementSource && video && mediaClockStart !== undefined &&
                  audio.currentTime - mediaClockStart -
                    Math.max(0, video.currentTime - clip.start) /
                      (clip.speed ?? 1) > MAX_ORIGINAL_AUDIO_LOSS_SECONDS) {
                if (++lossReadings > 1)
                  throw new Error("Original audio playback stalled during export. No download was created.");
              } else lossReadings = 0;
            }
            if (elementSource && video) {
              video.pause();
              await awaitMediaOperation(played!, signal, "Playing original source");
              if (video.currentTime < clip.end - .1)
                throw new Error("Original source ended early. No download was created.");
            }
          },
        });
        options.onProgress(Math.min(.45,
          (window.startFrame + window.frameCount) / plan.config.audioFrames * .45));
      } finally {
        try {
          video?.pause();
          if (bufferedOriginal) {
            try {bufferedOriginal.stop();} catch { /* naturally ended */ }
            bufferedOriginal.disconnect();
          }
          elementSource?.disconnect();
          originalGain?.disconnect();
          if (voiceSource) {
            try {voiceSource.stop();} catch { /* naturally ended */ }
            voiceSource.disconnect();
          }
          if (musicSource) {
            try {musicSource.stop();} catch { /* naturally ended */ }
            musicSource.disconnect();
          }
          voiceGain?.disconnect();
          musicGain?.disconnect();
        } finally {
          try {await session?.dispose();}
          finally {decoded?.dispose(); decoded = undefined;}
        }
      }
      if (prepared && !prepared.result) await prepared.settled;
    }
  } finally {
    decoded?.dispose();
    if (prepared) {
      const row = await prepared.settled;
      if ("media" in row) row.media.dispose();
    }
  }
}

/** Complete and encode the exact canonical audio sample count, then video may render offline. */
export async function encodeExportAudio(options: AudioOptions): Promise<void> {
  if (!options.plan.config.withAudio || options.plan.config.audioFrames < 1)
    throw new Error("The audio plan is missing. No download was created.");
  requireCurrent(options);
  await awaitMediaOperation(options.begun.resumeStarted, options.signal,
    "Starting export audio");
  const tracks = await loadTracks(options);
  if (requiresLivePCM(options.draft, options.plan))
    await captureHybrid(options, tracks);
  else await captureOffline(options, tracks);
  requireCurrent(options);
}
