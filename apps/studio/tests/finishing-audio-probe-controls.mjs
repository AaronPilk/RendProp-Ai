import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {closeSync, fsyncSync, openSync} from "node:fs";
import {mkdir, mkdtemp, readFile, stat, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {basename, dirname, isAbsolute, join} from "node:path";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";
import {fixedAACTailWindow, measureTonePCM, PCM_RATE, PROBE_SECONDS, requireAudibleFadeOut} from "./finishing-audio-probe.mjs";

process.umask(0o077);
const args = process.argv.slice(2), options = {};
for (let index = 0; index < args.length; index += 2) {
  assert(["--out", "--retained-mp4"].includes(args[index]) && args[index + 1] && !options[args[index]], "Exact control arguments required");
  options[args[index]] = args[index + 1];
}
const out = options["--out"];
if (out) {assert(isAbsolute(out)); await mkdir(out, {mode: 0o700});}
const artifacts = out ?? await mkdtemp(join(process.env.RUNNER_TEMP ?? tmpdir(), "rendprop-finishing-audio-probe-"));
const started = performance.now(), calls = [], checks = [];
const receipt = {status: "running", proof: "Offline test-only AAC/PCM measurements of synthetic files; optional retained failed CI artifact. No browser, provider, account or external requests.", checks, calls};
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
async function descriptor(path) {if (path instanceof URL) path = fileURLToPath(path); const bytes = await readFile(path); return {path, bytes: bytes.length, sha256: sha(bytes)};}
async function save(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, {flag: "wx", mode: 0o600});
  for (const target of [path, dirname(path)]) {const fd = openSync(target, "r"); try {fsyncSync(fd);} finally {closeSync(fd);}}
}
async function run(argv, label, maxBytes = 8 * 1024 * 1024) {
  assert(performance.now() - started < 300000, "Offline control phase deadline");
  const stdoutPath = join(artifacts, `${label}.stdout.raw`), stderrPath = join(artifacts, `${label}.stderr.log`);
  await save(join(artifacts, `${label}.intent.json`), {argv, timeoutSeconds: 60, maxBytes, localFilesOnly: true, retries: 0});
  assert(performance.now() - started < 300000, "Post-intent offline control deadline");
  const stdout = openSync(stdoutPath, "wx", 0o600), stderr = openSync(stderrPath, "wx", 0o600);
  const begin = performance.now(); let child, ended, code, failure;
  try {
    assert(performance.now() - started < 300000, "Prelaunch offline control deadline");
    child = spawn(argv[0], argv.slice(1), {stdio: ["ignore", stdout, stderr], detached: true});
    ended = new Promise((resolve, reject) => {child.once("error", reject); child.once("exit", result => resolve(result));});
    const deadline = Math.min(started + 300000, begin + 60000);
    while (child.exitCode === null && child.signalCode === null) {
      assert(performance.now() < deadline, "Offline media command timed out; no retry");
      assert((await stat(stdoutPath)).size <= maxBytes && (await stat(stderrPath)).size <= 1024 * 1024, "Offline command output bound");
      await Promise.race([ended, new Promise(resolve => setTimeout(resolve, 20))]);
    }
    code = await ended;
    assert.equal(code, 0, `Offline media command failed: ${label}`);
    assert((await stat(stdoutPath)).size <= maxBytes, "Offline command output bound");
  } catch (error) {
    failure = error;
    if (child?.pid) for (const signal of ["SIGTERM", "SIGKILL"]) {
      try {process.kill(-child.pid, signal);} catch (cleanup) {if (cleanup.code !== "ESRCH") throw cleanup;}
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (ended) await Promise.race([ended.catch(() => {}), new Promise(resolve => setTimeout(resolve, 1000))]);
    if (child?.pid) assert(child.exitCode !== null || child.signalCode !== null, "Owned offline child exit unknown");
  } finally {fsyncSync(stdout); fsyncSync(stderr); closeSync(stdout); closeSync(stderr);}
  const row = {argv, label, code, elapsedSeconds: (performance.now() - begin) / 1000,
    stdout: await descriptor(stdoutPath), stderr: await descriptor(stderrPath), failure: failure ? String(failure) : null};
  calls.push(row); await save(join(artifacts, `${label}.result.json`), row);
  if (failure) throw failure;
  return readFile(stdoutPath);
}
async function probe(file, label) {
  return JSON.parse(await run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,codec_type,start_time,duration,sample_rate:format=duration", "-of", "json", file], `${label}-probe`));
}
async function pcm(file, seconds, label) {
  return run(["ffmpeg", "-v", "error", "-ss", String(seconds), "-i", file, "-t", String(PROBE_SECONDS), "-vn", "-ac", "1", "-ar", String(PCM_RATE), "-f", "f32le", "pipe:1"], label);
}
function refusal(name, work, expected) {
  assert.throws(work, expected, name); checks.push({name, expected: "refusal", passed: true});
}
async function inspect(file, label, referenceTime) {
  const metadata = await probe(file, label), window = fixedAACTailWindow(metadata, 8);
  const tailBytes = await pcm(file, window.probeStart, `${label}-tail`), tail = measureTonePCM(tailBytes, 440);
  const reference = measureTonePCM(await pcm(file, referenceTime, `${label}-reference`), 440);
  requireAudibleFadeOut(tail.amplitude, reference.amplitude);
  return {metadata, window, tailBytes, tail, reference, ratio: tail.amplitude / reference.amplitude};
}
async function fixture(name, audioSeconds, filter) {
  const file = join(artifacts, `${name}.mp4`);
  await run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=10:d=8.4", "-f", "lavfi", "-i", `sine=frequency=440:sample_rate=48000:duration=${audioSeconds}`, "-af", filter, "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "8.4", file], `${name}-encode`);
  return file;
}
try {
  const faded = await fixture("faded-intact", 8, "volume=0.5,afade=t=out:st=7:d=1");
  const good = await inspect(faded, "faded", 2);
  checks.push({name: "declared-AAC-endpoint-measures-real-fade", expected: "pass", passed: true, window: good.window, tail: good.tail, reference: good.reference, ratio: good.ratio});
  const oldBytes = await pcm(faded, Number(good.metadata.format.duration) - .2, "old-format-window");
  assert.equal(oldBytes.length, 0, "Synthetic format tail must reproduce the empty old window");
  refusal("old-format-window-empty-is-rejected", () => measureTonePCM(oldBytes, 440), /PCM window is empty/);
  const shortened = await probe(await fixture("shortened-audio", 7.2, "volume=0.5,afade=t=out:st=6.2:d=1"), "shortened");
  refusal("materially-short-AAC-is-rejected", () => fixedAACTailWindow(shortened, 8), /does not cover the intended edit/);
  refusal("zero-PCM-is-not-fade-proof", () => measureTonePCM(Buffer.alloc(7200 * 4), 440), /finite audible audio/);
  for (const [name, value] of [["NaN", NaN], ["infinity", Infinity]]) {
    const invalid = Buffer.from(good.tailBytes); invalid.writeFloatLE(value, 0);
    refusal(`${name}-PCM-is-rejected`, () => measureTonePCM(invalid, 440), /nonfinite samples/);
  }
  refusal("partial-PCM-window-is-rejected", () => measureTonePCM(good.tailBytes.subarray(0, 3600 * 4), 440), /full requested duration/);
  const noFade = await fixture("missing-fade", 8, "volume=0.5");
  const noFadeProbe = await probe(noFade, "missing-fade"), noFadeWindow = fixedAACTailWindow(noFadeProbe, 8);
  const noFadeTail = measureTonePCM(await pcm(noFade, noFadeWindow.probeStart, "missing-fade-tail"), 440);
  const noFadeReference = measureTonePCM(await pcm(noFade, 2, "missing-fade-reference"), 440);
  refusal("missing-fade-is-rejected-at-the-same-half-threshold", () => requireAudibleFadeOut(noFadeTail.amplitude, noFadeReference.amplitude), /below half/);
  const padded = await fixture("silent-padded-no-fade", 8, "volume=0.5,apad=pad_dur=0.4"), paddedProbe = await probe(padded, "silent-padded");
  const paddedWindow = fixedAACTailWindow(paddedProbe, 8), paddedPCM = await pcm(padded, paddedWindow.probeStart, "silent-padded-tail");
  refusal("silent-padding-cannot-prove-an-unfaded-track-faded", () => {
    const tail = measureTonePCM(paddedPCM, 440);
    requireAudibleFadeOut(tail.amplitude, noFadeReference.amplitude);
  }, /finite audible audio|audible music/);
  const malformed = structuredClone(good.metadata); malformed.streams.find(stream => stream.codec_type === "audio").duration = "NaN";
  refusal("nonfinite-declared-endpoint-is-rejected", () => fixedAACTailWindow(malformed, 8), /Invalid AAC duration/);
  const wrongRate = structuredClone(good.metadata); wrongRate.streams.find(stream => stream.codec_type === "audio").sample_rate = "8000";
  refusal("wrong-fixture-rate-cannot-widen-the-codec-tolerance", () => fixedAACTailWindow(wrongRate, 8), /Invalid AAC sample rate/);
  if (options["--retained-mp4"]) {
    const retained = options["--retained-mp4"]; assert(isAbsolute(retained) && basename(retained) === "music-captions-mix.mp4");
    const original = JSON.parse(await readFile(join(dirname(retained), "receipt.json"), "utf8"));
    assert.equal(original.status, "fail"); assert.equal(original.levels.musicFadeOut, null);
    assert.equal((await descriptor(retained)).sha256, original.outputSHA256);
    const fixed = await inspect(retained, "retained-actual-CI", original.outputTiming.photoBoundary + 2.4);
    checks.push({name: "actual-retained-failed-MP4-fixed-probe-passes", expected: "pass", passed: true,
      originalCIStillFailed: true, media: await descriptor(retained), window: fixed.window,
      tail: fixed.tail, reference: fixed.reference, ratio: fixed.ratio});
  }
  assert(performance.now() - started < 300000, "Offline control phase deadline before acceptance");
  receipt.status = "pass";
} catch (error) {receipt.status = "fail"; receipt.failure = String(error.stack ?? error); throw error;}
finally {
  receipt.source = {helper: await descriptor(new URL("./finishing-audio-probe.mjs", import.meta.url)), controls: await descriptor(new URL(import.meta.url))};
  receipt.elapsedSeconds = (performance.now() - started) / 1000;
  await save(join(artifacts, "receipt.json"), receipt);
  console.log(JSON.stringify({status: receipt.status, artifacts, positive: checks.filter(row => row.expected === "pass").length, negative: checks.filter(row => row.expected === "refusal").length}));
}
