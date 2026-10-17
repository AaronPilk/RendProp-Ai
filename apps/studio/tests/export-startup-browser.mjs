import assert from "node:assert/strict";
import {mkdtemp, readFile, writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join, resolve, extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";
import {startNativeTraceObserver} from "./native-trace-observer.mjs";

const mode = process.argv[2] ?? "actual";
assert(["actual", "--before", "--fault=omit-readiness"].includes(mode));
const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-startup-"));
const paths = ["src/editor/export.ts", "src/editor/recording-clock.ts", "src/editor/media.ts", "src/editor/model.ts",
  "tests/export-startup-fixture.ts", "tests/export-startup-fixture.html", "tests/export-startup-browser.mjs", "tests/native-trace-observer.mjs"];
const hashes = async () => Object.fromEntries(await Promise.all(paths.map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = {status: "running", mode, sourceHashes: await hashes(), cases: [], checks: [], externalRequests: [], errors: [],
  proof: "Native Web Audio/canvas/MediaRecorder and decoded PCM. Explicit startup currentTime observation hold; real native time retained independently. No claim to reproduce the underlying hosted browser/device cause."};
let browser, server, page, mutated = false;
let nativeTraceOwner;
// Passive native tracing for the actual first freeze/MP4 case only. This owns
// no product clock/source/graph and never turns an export refusal into success.
// The observer itself lives in native-trace-observer.mjs, shared with the
// finishing and export-resume suites; its categories, limits, raw-file policy
// and receipt fields are unchanged from when it was defined here.
async function startNativeStartupTrace(context, page) {
  const {finish} = await startNativeTraceObserver({context, page, artifacts, syncId: "startup-freeze-mp4-before-click",
    rawFileName: "native-trace-freeze-mp4.raw.private.json", sourceHashes: receipt.sourceHashes, onFacts: facts => {receipt.nativeTrace = facts;}});
  return {finish};
}

try {
  const before = mode === "--before" ? await readFile(process.env.STARTUP_BEFORE_EXPORT, "utf8") : undefined;
  if (before) receipt.beforeSourceSHA256 = createHash("sha256").update(before).digest("hex");
  const dist = join(artifacts, "dist");
  await build({configFile: false, root, publicDir: false, logLevel: "error", plugins: mode === "actual" ? [] : [{
    name: "startup-causal-control", enforce: "pre", transform(code, id) {
      if (!id.endsWith("/src/editor/export.ts")) return;
      mutated = true;
      if (before) return before;
      const start = '        if (audio) await awaitAudioStartup(audio, renderSignal,', end = '          });';
      assert.equal(code.split(start).length, 2, "Readiness omission must match the actual first-start admission");
      const at = code.indexOf(start), finish = code.indexOf(end, at) + end.length;
      assert(finish > at); return code.slice(0, at) + "        // omitted startup readiness" + code.slice(finish);
    },
  }], build: {outDir: dist, rollupOptions: {input: join(root, "tests/export-startup-fixture.html")}}});
  if (mode !== "actual") assert(mutated);
  server = createServer(async (req, res) => {
    const path = resolve(dist, `.${new URL(req.url, "http://localhost").pathname}`);
    if (!path.startsWith(dist + "/") || req.method !== "GET") return res.writeHead(400).end();
    try {res.setHeader("Content-Type", ({".html": "text/html", ".js": "application/javascript"})[extname(path)] ?? "application/octet-stream"); res.end(await readFile(path));}
    catch {res.writeHead(404).end();}
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  const source = join(artifacts, "opening-middle-tail.mp4");
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=green:s=640x360:r=30:d=1.5",
    "-f", "lavfi", "-i", "sine=frequency=990:duration=0.12", "-f", "lavfi", "-i", "sine=frequency=440:duration=1.08",
    "-f", "lavfi", "-i", "sine=frequency=660:duration=0.3", "-filter_complex", "[1:a][2:a][3:a]concat=n=3:v=0:a=1[a]",
    "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source]);
  browser = await chromium.launch({headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE});
  const context = await browser.newContext({serviceWorkers: "block", viewport: {width: 1000, height: 800}});
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin === origin && route.request().method() === "GET" || url.protocol === "blob:") return route.continue();
    receipt.externalRequests.push(url.href); return route.abort();
  });
  page = await context.newPage(); page.setDefaultTimeout(15000); page.on("pageerror", error => receipt.errors.push(error.message));
  const run = async (scenario, extension = "mp4") => {
    await page.goto(`${origin}/tests/export-startup-fixture.html`);
    await page.getByLabel("Synthetic source").setInputFiles(source);
    await page.evaluate(({scenario, extension}) => Object.assign(window.startupFixture, {mode: scenario, extension}), {scenario, extension});
    const nativeTrace = mode === "actual" && receipt.cases.length === 0 && scenario === "freeze" && extension === "mp4"
      ? await startNativeStartupTrace(context, page) : undefined;
    if (nativeTrace) nativeTraceOwner = nativeTrace;
    try {
      await page.getByRole("button", {name: "Export fixture", exact: true}).click();
      await expect.poll(() => page.evaluate(() => window.startupFixture.result !== null ||
        window.startupFixture.events.some(event => event.kind === "startup.released" ||
          event.held && (event.kind === "recorder.start" || event.kind.startsWith("user."))))).toBe(true);
      const earlyEvents = await page.evaluate(() => window.startupFixture.events);
      receipt.earlyEvents = earlyEvents;
      assert.deepEqual(earlyEvents.filter(event => event.held && (event.kind === "recorder.start" || event.kind.startsWith("user."))), [],
        "Content and recording must not start while startup clock is frozen");
      await expect.poll(() => page.evaluate(() => window.startupFixture.result), {timeout: 15000}).not.toBeNull();
    } finally {
      if (nativeTrace) await nativeTrace.finish();
    }
    const result = await page.evaluate(() => window.startupFixture.result), events = await page.evaluate(() => window.startupFixture.events);
    const record = {scenario, extension, ...result, events}; delete record.base64; receipt.cases.push(record);
    const content = events.filter(event => event.kind.startsWith("user.") || event.kind === "recorder.start");
    assert.deepEqual(content.filter(event => event.held), [], "Content and recording must not start while startup clock is frozen");
    assert(result.tracks.length >= 1 && result.tracks.every(state => state === "ended"), "Every created audio/capture track must end");
    assert.equal(result.audioState, "closed", "The owned audio context must close");
    if (["permanent", "abort", "stale", "suspended"].includes(scenario)) {
      assert.equal(result.ok, false); assert.equal(result.base64, undefined); assert.equal(content.length, 0);
      assert.deepEqual(result.trackKinds, ["audio"], "A pre-capture refusal creates only the owned audio destination");
      assert.deepEqual(events.filter(event => event.kind === "capture.create" || event.kind === "recorder.construct"), [],
        "Refused readiness must create no canvas capture track or recorder");
      assert.match(result.error, ({permanent: /Audio did not begin advancing/, abort: /Fixture startup cancelled/, stale: /edit changed/, suspended: /Audio stopped before recording/})[scenario]);
      return;
    }
    assert.equal(result.ok, true, result.error);
    assert.deepEqual([...result.trackKinds].sort(), ["audio", "video"], "The successful export must retain both real capture tracks");
    assert.equal(content.filter(event => event.kind === "recorder.start").length, 1);
    assert.equal(content.filter(event => event.kind === "user.buffer.start").length, 1);
    const output = join(artifacts, `${scenario}.${extension}`); await writeFile(output, Buffer.from(result.base64, "base64"));
    const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", output], {encoding: "utf8"})); record.probe = probe;
    // Streaming WebM may omit a duration header. Measure its actual packet end
    // timestamps rather than treating absent metadata as an encoded duration.
    const packets = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_packets", "-of", "json", output], {encoding: "utf8"})).packets;
    const packetEnd = Math.max(...packets.map(packet => Number(packet.pts_time) + Number(packet.duration_time ?? 0)));
    const duration = probe.format.duration === undefined ? packetEnd : Number(probe.format.duration);
    record.packetEndSeconds = packetEnd; record.durationSeconds = duration;
    assert(Number.isFinite(duration) && Math.abs(duration - 1.5) < .18, "Startup must not add a silent/static prefix to duration");
    const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", output, "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
    const measure = (at, seconds = .04) => {
      let power = 0, crossings = 0; const first = Math.floor(at * 48000), count = Math.floor(seconds * 48000);
      assert((first + count) * 2 <= pcm.length);
      for (let index = first; index < first + count; index++) {
        const value = pcm.readInt16LE(index * 2) / 32768; power += value * value;
        if (index > first && value >= 0 && pcm.readInt16LE((index - 1) * 2) < 0) crossings++;
      }
      return {at, rms: Math.sqrt(power / count), frequency: crossings / seconds};
    };
    let onset;
    for (let at = 0; at < .15; at += .001) if (measure(at, .01).rms > .03) {onset = at; break;}
    assert(onset !== undefined && onset <= 2 / 30, "Original opening onset must stay within the unchanged two-frame timing limit");
    record.onsetSeconds = onset;
    record.pcm = [measure(onset + .015), measure(onset + .055), measure(.35), measure(1.3)];
    for (const [index, frequency] of [990, 990, 440, 660].entries()) {
      assert(record.pcm[index].rms > .03, "The original opening/middle/tail audio must all survive startup");
      assert(Math.abs(record.pcm[index].frequency - frequency) < 65, "Opening/middle/tail timing and pitch must remain unchanged");
    }
    const capture = events.filter(event => event.kind === "capture.create"), constructed = events.filter(event => event.kind === "recorder.construct");
    assert.equal(capture.length, 1); assert.equal(constructed.length, 1);
    const released = events.find(event => event.kind === "startup.released"), start = events.find(event => event.kind === "recorder.start");
    assert(released && start && capture[0].wall >= released.wall && constructed[0].wall >= capture[0].wall && start.wall >= constructed[0].wall,
      "Fresh capture and recorder must be constructed after startup release and before recording starts");
  };
  await run("freeze"); receipt.checks.push("A held observed running clock permits no content/recorder start; actual MP4 retains opening, middle and tail PCM with exact planned duration");
  await run("freeze", "webm"); receipt.checks.push("The same startup admits an offered WebM without awaiting its start event or losing original PCM");
  for (const scenario of ["permanent", "abort", "stale", "suspended"]) await run(scenario);
  receipt.checks.push("Persistent freeze, cancellation, stale edit and native suspension all refuse before recording/playback and clean every track/context");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = String(error.stack ?? error); process.exitCode = 1;
  if (page) receipt.failureSnapshot = await page.evaluate(() => ({events: window.startupFixture?.events, result: window.startupFixture?.result})).catch(() => null);
}
finally {
  if (nativeTraceOwner) await nativeTraceOwner.finish();
  await browser?.close(); if (server) await new Promise(done => server.close(done));
  receipt.sourceBoundAtEnd = JSON.stringify(await hashes()) === JSON.stringify(receipt.sourceHashes);
  if (!receipt.sourceBoundAtEnd) {receipt.status = "failed"; process.exitCode = 1;}
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({...receipt, artifacts}, null, 2));
}
