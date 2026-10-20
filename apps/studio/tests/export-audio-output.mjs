import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

// Test transport only. Production AudioContext options and all media/timing
// oracles stay unchanged. A silent native sink still processes the real graph.
const helperSha256 = createHash("sha256").update(await readFile(new URL(import.meta.url))).digest("hex");
export function testAudioOutputOption(args) {
  const selected = args.filter(argument => argument === "--silent-audio-output");
  assert(selected.length <= 1, "Duplicate --silent-audio-output option");
  return { args: args.filter(argument => argument !== "--silent-audio-output"),
    audioOutput: { mode: selected.length ? "silent-native-sink" : "default-device", helperSha256, testOnly: true } };
}

export async function installTestAudioOutput(context, option) {
  assert(["default-device", "silent-native-sink"].includes(option.mode), "Unknown test audio output mode");
  if (option.mode === "default-device") return; // Default browser behavior is untouched.
  await context.addInitScript(() => {
    const NativeAudio = globalThis.AudioContext;
    const nativeTime = typeof BaseAudioContext === "function"
      ? Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "currentTime")?.get : undefined;
    const contexts = [];
    let failure = null;
    const supported = typeof NativeAudio === "function" && typeof NativeAudio.prototype.setSinkId === "function" &&
      "sinkId" in NativeAudio.prototype && typeof nativeTime === "function";
    globalThis.__rendpropTestAudioOutput = () => ({ mode: "silent-native-sink", supported, installed: supported,
      failure, nativeClockGetterUnchanged: typeof BaseAudioContext === "function" &&
        Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "currentTime")?.get === nativeTime,
      contexts: contexts.map(audio => ({ sinkType: typeof audio.sinkId === "object" ? audio.sinkId?.type : null,
        nativeTime: nativeTime.call(audio), sampleRate: audio.sampleRate, state: audio.state })) });
    if (!supported) { failure = "This browser cannot select the test-only silent native audio sink"; return; }
    globalThis.AudioContext = class extends NativeAudio {
      constructor(options) {
        super({ ...options, sinkId: { type: "none" } });
        contexts.push(this);
        if (typeof this.sinkId !== "object" || this.sinkId?.type !== "none") {
          failure = "The browser did not select the requested silent native audio sink";
          void this.close();
          throw new Error(failure);
        }
      }
    };
  });
}

export async function verifyTestAudioOutput(page, option) {
  if (option.mode === "default-device") return { ...option, installed: false };
  const evidence = await page.evaluate(() => globalThis.__rendpropTestAudioOutput?.() ?? null);
  assert(evidence?.supported && evidence.installed && !evidence.failure, evidence?.failure ?? "Silent test audio output was not installed");
  assert(evidence.nativeClockGetterUnchanged, "Silent sink must retain the native audio clock getter");
  for (const audio of evidence.contexts) {
    assert.equal(audio.sinkType, "none", "Every test AudioContext must use the actual silent native sink");
    assert(Number.isFinite(audio.nativeTime) && audio.nativeTime >= 0, "The native audio clock must remain readable");
  }
  return { ...option, ...evidence };
}
