#!/usr/bin/env python3
"""Derive external audible-original draft from frozen narrated/muted v2 proof.

Static preparation only. No source checkout, browser, encoder or package write.
"""
from __future__ import annotations
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / "webcodecs-narrated-prototype-v2/experimental-webcodecs.ts"
EXPECTED_BASE = "773e6860f48963746f4233c240292dca63092e288493c6bc43fbbb9c51b437a3"
DEST = HERE / "experimental-webcodecs-audible.ts"

def once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one exact anchor, found {count}")
    return source.replace(old, new, 1)

def video_block(source: str) -> str:
    start = source.index("    const frames = EXPECTED_SECONDS * FPS;")
    end = source.index("    videoSource.close();", start) + len("    videoSource.close();")
    return source[start:end]

def main() -> None:
    if hashlib.sha256(BASE.read_bytes()).hexdigest() != EXPECTED_BASE:
        raise RuntimeError("Frozen narrated v2 source changed")
    original = BASE.read_text()
    source = original
    source = once(source, " * This exercises the existing three-second narrated fixture with real LocalMedia",
                  " * This exercises a separate three-second audible-original fixture with real LocalMedia", "scope header")
    source = once(source, " * arbitrary customer drafts. It has not been installed, compiled, or run.",
                  " * arbitrary customer drafts. Only external static checks have run.", "truthful scope header")
    source = once(source, "  AudioBufferSource,\n", "  AudioSampleSource,\n", "audio source import")
    source = once(source, 'import {OverlayPainter} from "./overlay-renderer";',
                  'import {captureAudibleOriginalProof, beginAudibleProofAudio, type AudibleTrace} from "./audible-pcm";\nimport {OverlayPainter} from "./overlay-renderer";', "capture import")
    source = once(source, '''  if (draft.audio !== "muted" || draft.music || options.musicBlob ||
      draft.overlays?.length || draft.speech?.length || !draft.narration ||
      draft.clips.length !== 3 ||
      draft.clips[0]?.source.kind !== "image" ||
      draft.clips[1]?.source.kind !== "video" ||
      draft.clips[2]?.source.kind !== "image" ||
      draft.clips[1]?.speed !== 2 ||
      Math.abs(timelineDuration(draft.clips) - EXPECTED_SECONDS) > 0.00001) {
    throw new Error("WebCodecs proof only supports the muted-source, three-second narrated test edit. No download was created.");
  }
  if (options.format.extension !== "mp4" || !options.narrationBlob?.size ||
      options.narrationBlob.size > EDIT_LIMITS.narrationBytes) {
    throw new Error("WebCodecs proof requires MP4 and the restored narration. No download was created.");
  }''',
'''  if (draft.audio !== "original" || draft.music || options.musicBlob ||
      draft.overlays?.length || draft.speech?.length || draft.narration ||
      options.narrationBlob || draft.clips.length !== 3 ||
      draft.clips[0]?.source.kind !== "image" ||
      draft.clips[1]?.source.kind !== "video" ||
      draft.clips[2]?.source.kind !== "image" ||
      draft.clips[1]?.speed !== 2 ||
      Math.abs(clipDuration(draft.clips[0]) - .5) > .00001 ||
      Math.abs(clipDuration(draft.clips[1]) - 2) > .00001 ||
      Math.abs(clipDuration(draft.clips[2]) - .5) > .00001 ||
      Math.abs(timelineDuration(draft.clips) - EXPECTED_SECONDS) > .00001) {
    throw new Error("Audible proof only supports the exact three-second original-audio test edit. No download was created.");
  }
  if (options.format.extension !== "mp4") {
    throw new Error("Audible proof requires MP4. No download was created.");
  }''', "narrow audible scope")
    beginning = source.index("async function narrationMix(")
    ending = source.index("function trackTransitions(", beginning)
    source = source[:beginning] + source[ending:]
    source = once(source, "export async function exportNarratedWebCodecsProof(options: ProofOptions): Promise<LocalExport> {",
                  "export async function exportAudibleWebCodecsProof(options: ProofOptions): Promise<LocalExport> {", "export name")
    source = once(source, "  const dims = renderDimensions(draft.ratio);",
                  "  const begunAudio = beginAudibleProofAudio();\n  try {\n  const dims = renderDimensions(draft.ratio);", "gesture audio")
    source = once(source, "    numberOfChannels: 1, sampleRate: SAMPLE_RATE,",
                  "    numberOfChannels: 2, sampleRate: SAMPLE_RATE,", "stereo capability")
    source = once(source, '  const trace = {kind: "webcodecs-narrated-proof", requested: 0,',
                  '  const trace = {kind: "webcodecs-audible-original-proof", requested: 0,\n    audio: undefined as AudibleTrace | undefined,', "trace scope")
    source = once(source,
                  '(window as typeof window & {webCodecsNarratedProof?: typeof trace}).webCodecsNarratedProof = trace;',
                  '(window as typeof window & {webCodecsAudibleProof?: typeof trace}).webCodecsAudibleProof = trace;',
                  "trace global")
    source = once(source, "  const audioSource = new AudioBufferSource({",
                  "  const audioSource = new AudioSampleSource({", "sample source")
    source = once(source, '''    const mixedNarration = await narrationMix(draft, options.narrationBlob!, signal);
    assertCurrentRevision(draft, options.currentDraft(), signal);
    await awaitMediaOperation(output.start(), signal, "Starting proof MP4 output");
    await awaitMediaOperation(audioSource.add(mixedNarration), signal, "Encoding proof narration");
    audioSource.close();''',
'''    assertCurrentRevision(draft, options.currentDraft(), signal);
    await awaitMediaOperation(output.start(), signal, "Starting proof MP4 output");
    trace.audio = await captureAudibleOriginalProof({
      begun: begunAudio, draft, media: options.media, audioSource, signal,
      currentDraft: options.currentDraft, fail: error => controller.abort(error),
    });
    audioSource.close();''', "progressive audible phase")
    source = once(source, '''      duration: EXPECTED_SECONDS, audio: draft.audio, narration: true};''',
                  '''      duration: EXPECTED_SECONDS, audio: draft.audio};''', "result scope")
    # The last brace closes the function; an outer finally owns the gesture-created
    # context even when codec capability checks fail before the inner try begins.
    if not source.endswith("}\n"):
        raise RuntimeError("Unexpected function ending")
    source = source[:-2] + '''  } finally {
    const audio = begunAudio.context;
    if (audio.state !== "closed") {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const closed = await Promise.race([
        audio.close().then(() => true, () => false),
        new Promise<false>(resolve => {timeout = setTimeout(() => resolve(false), 2000);}),
      ]);
      if (timeout !== undefined) clearTimeout(timeout);
      const state = (): AudioContextState => audio.state;
      if (!closed || state() !== "closed")
        throw new Error("The proof AudioContext did not close. No download was created.");
    }
    (window as typeof window & {audibleProofOuterAudioState?: AudioContextState}).audibleProofOuterAudioState = audio.state;
  }
}
'''
    if video_block(source) != video_block(original):
        raise RuntimeError("Frozen explicit 90-frame video loop changed")
    if DEST.exists():
        raise RuntimeError(f"Refusing overwrite of {DEST}")
    DEST.write_text(source)
    print(f"Derived external audible exporter; unchanged 90-frame video block SHA256 {hashlib.sha256(video_block(source).encode()).hexdigest()}")
    print(f"Audible module SHA256 {hashlib.sha256(DEST.read_bytes()).hexdigest()}")

if __name__ == "__main__":
    main()
