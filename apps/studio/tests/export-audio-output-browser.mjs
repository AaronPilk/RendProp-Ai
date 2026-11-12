import assert from "node:assert/strict";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve, join } from "node:path";
import { chromium } from "@playwright/test";
import { testAudioOutputOption, installTestAudioOutput, verifyTestAudioOutput } from "./export-audio-output.mjs";

// Closed real-browser proof of the transport choice, independent of all existing
// product timing/media oracles. No account, microphone, provider or external GET.
assert(process.env.RENDPROP_AUDIO_SINK_EVIDENCE, "Set a new evidence directory explicitly");
const evidence = resolve(process.env.RENDPROP_AUDIO_SINK_EVIDENCE);
await mkdir(evidence, { recursive: false });
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const receipt = { status: "running", testOnly: true, sourceHashes: Object.fromEntries(await Promise.all(
  ["export-audio-output.mjs", "export-audio-output-browser.mjs"].map(async name => [name, sha(await readFile(new URL(name, import.meta.url)))]))),
  externalRequests: [], checks: [], scenarios: [] };
let browser;
try {
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  receipt.browser = browser.version();
  for (const scenario of ["default", "missing-install", "unsupported", "ignored", "silent"]) {
    const option = testAudioOutputOption(scenario === "default" ? [] : ["--silent-audio-output"]).audioOutput;
    const context = await browser.newContext({ serviceWorkers: "block" });
    await context.route("**/*", route => {
      if (route.request().url() === "http://127.0.0.1/audio-output-proof" && route.request().method() === "GET")
        return route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>Native audio sink proof</title>" });
      receipt.externalRequests.push(route.request().url()); return route.abort();
    });
    // Install the exact helper initializer and the availability/ignored-option
    // control in one script; Playwright does not promise ordering between
    // separately registered init scripts.
    let initializer;
    if (scenario !== "missing-install") await installTestAudioOutput({ addInitScript: async fn => { initializer = fn; } }, option);
    if (initializer) {
      const fault = scenario === "unsupported"
        ? 'Object.defineProperty(AudioContext.prototype,"setSinkId",{value:undefined,configurable:true});'
        : scenario === "ignored"
          ? 'const NativeAudio=AudioContext;globalThis.AudioContext=class extends NativeAudio{constructor(options){const {sinkId,...rest}=options??{};super(rest);}};'
          : '';
      await context.addInitScript({ content: `${fault}(${initializer.toString()})();` });
    }
    const page = await context.newPage();
    await page.goto("http://127.0.0.1/audio-output-proof");
    const row = { scenario };
    receipt.scenarios.push(row);
    if (["missing-install", "unsupported"].includes(scenario)) {
      await assert.rejects(verifyTestAudioOutput(page, option));
      row.refusedBeforeExport = true;
    } else if (scenario === "ignored") {
      const failure = await page.evaluate(() => { try { new AudioContext({ sampleRate: 48000 }); return null; } catch (error) { return String(error); } });
      assert.match(failure, /did not select/);
      await assert.rejects(verifyTestAudioOutput(page, option), /did not select/);
      row.actualConstructorRefused = true;
    } else if (scenario === "default") {
      row.audioOutput = await verifyTestAudioOutput(page, option);
      const actual = await page.evaluate(async () => {
        const native = AudioContext.prototype.resume, audio = new AudioContext({ sampleRate: 48000 });
        const sink = audio.sinkId;
        await audio.close();
        return { sinkIsNone: typeof sink === "object" && sink?.type === "none", nativeResumeRetained: native === AudioContext.prototype.resume,
          helperInstalled: typeof globalThis.__rendpropTestAudioOutput === "function" };
      });
      assert.equal(actual.helperInstalled, false); assert.equal(actual.sinkIsNone, false);
      row.beforeControl = actual;
    } else {
      await verifyTestAudioOutput(page, option);
      const actual = await page.evaluate(async () => {
        const audio = new AudioContext({ sampleRate: 48000 });
        const oscillator = audio.createOscillator(), gain = audio.createGain(), destination = audio.createMediaStreamDestination();
        oscillator.frequency.value = 440; gain.gain.value = 0.2;
        oscillator.connect(gain); gain.connect(destination); gain.connect(audio.destination);
        const mime = "audio/webm;codecs=opus";
        if (!MediaRecorder.isTypeSupported(mime)) throw new Error("Native Opus recorder unavailable");
        const recorder = new MediaRecorder(destination.stream, { mimeType: mime });
        const pieces = []; recorder.addEventListener("dataavailable", event => { if (event.data.size) pieces.push(event.data); });
        const stopped = new Promise(resolve => recorder.addEventListener("stop", resolve, { once: true }));
        await audio.resume();
        const before = audio.currentTime, nativeGetter = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "currentTime").get;
        recorder.start(); oscillator.start();
        await new Promise(resolve => setTimeout(resolve, 300));
        const after = audio.currentTime;
        oscillator.stop(); recorder.stop(); await stopped;
        const blob = new Blob(pieces, { type: mime });
        const bytes = new Uint8Array(await blob.arrayBuffer());
        destination.stream.getTracks().forEach(track => track.stop()); await audio.close();
        return { before, after, nativeGetterAgrees: nativeGetter.call(audio) === audio.currentTime, mime,
          base64: btoa(String.fromCharCode(...bytes)), tracksEnded: destination.stream.getTracks().every(track => track.readyState === "ended") };
      });
      assert(actual.after > actual.before, "Silent sink must advance the actual native audio clock");
      assert(actual.nativeGetterAgrees && actual.tracksEnded);
      const file = join(evidence, "native-silent-tone.webm");
      await writeFile(file, Buffer.from(actual.base64, "base64"));
      const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", file, "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
      let power = 0;
      for (let at = 0; at < pcm.length; at += 2) power += (pcm.readInt16LE(at) / 32768) ** 2;
      const rms = Math.sqrt(power / (pcm.length / 2));
      assert(pcm.length > 0 && rms > 0.03, "Silent native output must retain real, audible-amplitude recorded PCM");
      delete actual.base64;
      Object.assign(row, { ...actual, pcmBytes: pcm.length, rms, recordingSha256: sha(await readFile(file)), audioOutput: await verifyTestAudioOutput(page, option) });
    }
    await context.close();
  }
  assert.deepEqual(receipt.externalRequests, []);
  receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = String(error); throw error;
} finally {
  await browser?.close();
  await writeFile(join(evidence, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
}
console.log(JSON.stringify({ status: receipt.status, evidence, scenarios: receipt.scenarios.map(row => row.scenario) }));
