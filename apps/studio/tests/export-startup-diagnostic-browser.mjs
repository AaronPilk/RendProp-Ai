import assert from "node:assert/strict";
import {mkdtemp, readFile, writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join, resolve, extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";

const mode = "diagnostic-single-freeze-mp4";
assert.equal(process.argv.length, 2, "No mode/retry matrix is admitted");
const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-startup-diagnostic-"));
const paths = ["src/editor/export.ts", "src/editor/recording-clock.ts", "src/editor/media.ts", "src/editor/model.ts",
  "tests/export-startup-diagnostic-fixture.ts", "tests/export-startup-diagnostic-fixture.html", "tests/export-startup-diagnostic-browser.mjs"];
const hashes = async () => Object.fromEntries(await Promise.all(paths.map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = {status: "running", mode, sourceHashes: await hashes(), cases: [], checks: [], externalRequests: [], errors: [],
  proof: "Native Web Audio/canvas/MediaRecorder and decoded PCM. Explicit startup currentTime observation hold; real native time retained independently. Instrumentation can perturb timing; no claim to reproduce or prove the underlying hosted browser/device cause."};
let browser, server, page, mutated = false;
try {
  const expected = {"src/editor/export.ts": "6df7d47c4bb70df2e7e30575a12037a806fa00634bbb43a3ddf7829a31672e5d", "src/editor/recording-clock.ts": "7d804d9d46135ee740b70affbefdc88fe3dd77e2b4fcd799e2165fe0b4e0a5f8", "src/editor/media.ts": "82353070aaa85733ad89583fc52dedef36a9296cd6e4f594910571e7597b939b", "src/editor/model.ts": "9696653581899e097d0b0e8ce395c9c80d5e6f264cd8f17411a6ff5545dfa8dd"};
  for (const [path, sha] of Object.entries(expected)) assert.equal(receipt.sourceHashes[path], sha, "Production input must remain exact");
  const dist = join(artifacts, "dist");
  await build({configFile: false, root, publicDir: false, logLevel: "error",
    build: {outDir: dist, rollupOptions: {input: join(root, "tests/export-startup-diagnostic-fixture.html")}}});
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
  page = await context.newPage();
  receipt.backend = {browserVersion: browser.version(), platform: process.platform, architecture: process.arch,
    nodeVersion: process.version, unavailable: [], observationMayPerturbTiming: true};
  const browserCDP = await browser.newBrowserCDPSession();
  try {receipt.backend.version = await browserCDP.send("Browser.getVersion");}
  catch {receipt.backend.unavailable.push("Browser.getVersion unsupported");}
  try {receipt.backend.commandLine = await browserCDP.send("Browser.getBrowserCommandLine");}
  catch {receipt.backend.unavailable.push("Browser.getBrowserCommandLine unsupported");}
  await browserCDP.detach();
  const cdp = await context.newCDPSession(page), pendingMetrics = new Set();
  let contextID, metricCount = 0;
  receipt.cdp = {supported: false, contexts: [], metrics: [], unavailable: []};
  cdp.on("WebAudio.contextCreated", ({context}) => {contextID = context.contextId; receipt.cdp.contexts.push(context);});
  cdp.on("WebAudio.contextChanged", ({context}) => {if (receipt.cdp.contexts.length < 32) receipt.cdp.contexts.push(context);});
  try {await cdp.send("WebAudio.enable"); receipt.cdp.supported = true;}
  catch {receipt.cdp.unavailable.push("WebAudio.enable unsupported");}
  await page.exposeFunction("startupDiagnosticMetric", wall => {
    if (!receipt.cdp.supported || !contextID || metricCount++ >= 8) return;
    const requestedAt = performance.now();
    const task = Promise.race([cdp.send("WebAudio.getRealtimeData", {contextId: contextID}),
      new Promise((_, reject) => {const timer = setTimeout(() => reject(Error("metric deadline")), 1000); timer.unref();})])
      .then(value => receipt.cdp.metrics.push({pageWall: wall, requestedAt, receivedAt: performance.now(), ...value}))
      .catch(() => receipt.cdp.unavailable.push("Realtime metric unavailable"));
    pendingMetrics.add(task); task.finally(() => pendingMetrics.delete(task));
  });
  page.setDefaultTimeout(15000); page.on("pageerror", error => receipt.errors.push(error.message));
  const run = async (scenario, extension = "mp4") => {
    await page.goto(`${origin}/tests/export-startup-diagnostic-fixture.html`);
    await page.getByLabel("Synthetic source").setInputFiles(source);
    await page.evaluate(({scenario, extension}) => Object.assign(window.startupFixture, {mode: scenario, extension}), {scenario, extension});
    await page.getByRole("button", {name: "Export fixture", exact: true}).click();
    await expect.poll(() => page.evaluate(() => window.startupFixture.result !== null ||
      window.startupFixture.events.some(event => event.kind === "startup.released" ||
        event.held && (event.kind === "recorder.start" || event.kind.startsWith("user."))))).toBe(true);
    const earlyEvents = await page.evaluate(() => window.startupFixture.events);
    receipt.earlyEvents = earlyEvents;
    assert.deepEqual(earlyEvents.filter(event => event.held && (event.kind === "recorder.start" || event.kind.startsWith("user."))), [],
      "Content and recording must not start while startup clock is frozen");
    await expect.poll(() => page.evaluate(() => window.startupFixture.result), {timeout: 15000}).not.toBeNull();
    const result = await page.evaluate(() => window.startupFixture.result), events = await page.evaluate(() => window.startupFixture.events);
    const diagnostics = await page.evaluate(() => window.startupFixture.diagnostics);
    const record = {scenario, extension, ...result, events, diagnostics};
    delete record.base64; delete record.partialBase64; receipt.cases.push(record);
    await Promise.allSettled([...pendingMetrics]);
    if (!result.ok) {
      record.partialAnalysis = {classification: "REFUSED_PARTIAL_NOT_A_DOWNLOAD", fullPlannedDurationClaim: false};
      if (result.partialBase64 && !result.partialCapped) {
        const output = join(artifacts, "REFUSED-PARTIAL-NOT-A-DOWNLOAD.mp4");
        const bytes = Buffer.from(result.partialBase64, "base64"); await writeFile(output, bytes);
        Object.assign(record.partialAnalysis, {file: output, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex")});
        try {
          const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", output], {encoding: "utf8", timeout: 15000, maxBuffer: 4 * 1024 * 1024}));
          const packets = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_packets", "-of", "json", output], {encoding: "utf8", timeout: 15000, maxBuffer: 8 * 1024 * 1024})).packets;
          const spans = probe.streams.map(stream => {
            const rows = packets.filter(p => Number(p.stream_index) === stream.index).map(p => ({pts: Number(p.pts_time), duration: Number(p.duration_time ?? 0)}));
            return {index: stream.index, kind: stream.codec_type, packets: rows.length, firstPTS: rows[0]?.pts,
              endPTS: rows.length ? Math.max(...rows.map(p => p.pts + p.duration)) : null,
              largestPositiveGap: rows.length > 1 ? Math.max(0, ...rows.slice(1).map((p, i) => p.pts - rows[i].pts - rows[i].duration)) : null};
          });
          const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", output, "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"], {timeout: 15000, maxBuffer: 32 * 1024 * 1024});
          const windows = []; let longestSilent = 0, silent = 0, droppedWindows = 0;
          for (let start = 0; start + 480 <= pcm.length / 2; start += 480) {
            let power = 0, crossings = 0;
            for (let i = start; i < start + 480; i++) {const v = pcm.readInt16LE(i * 2) / 32768; power += v * v;
              if (i > start && v >= 0 && pcm.readInt16LE((i - 1) * 2) < 0) crossings++;}
            const rms = Math.sqrt(power / 480); silent = rms < .01 ? silent + .01 : 0; longestSilent = Math.max(longestSilent, silent);
            if (windows.length < 2000) windows.push({at: start / 48000, rms, frequency: crossings / .01}); else droppedWindows++;
          }
          Object.assign(record.partialAnalysis, {status: "measured", probe, packetSpans: spans, pcmSamples: pcm.length / 2,
            pcmSeconds: pcm.length / 2 / 48000, longestLowEnergySeconds: longestSilent, pcm10ms: windows, droppedWindows,
            interpretation: "Measurements only; aborted recording and codec padding prevent a full1.5s/tail claim."});
        } catch (error) {Object.assign(record.partialAnalysis, {status: "unknown-undecodable", analysisError: String(error.message).slice(0, 500)});}
      } else Object.assign(record.partialAnalysis, {status: "unknown-no-partial", capped: result.partialCapped});
    }
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
  await run("freeze"); receipt.checks.push("Single freeze/MP4 retains unchanged readiness/order/duration/onset/PCM assertions");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = String(error.stack ?? error); process.exitCode = 1;
  if (page) receipt.failureSnapshot = await page.evaluate(() => {
    const result = {...window.startupFixture?.result}; delete result.base64; delete result.partialBase64;
    return {events: window.startupFixture?.events, result, diagnostics: window.startupFixture?.diagnostics};
  }).catch(() => null);
}
finally {
  await browser?.close(); if (server) await new Promise(done => server.close(done));
  receipt.sourceBoundAtEnd = JSON.stringify(await hashes()) === JSON.stringify(receipt.sourceHashes);
  if (!receipt.sourceBoundAtEnd) {receipt.status = "failed"; process.exitCode = 1;}
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({status: receipt.status, mode, failure: receipt.failure?.split("\n")[0],
    sourceBoundAtEnd: receipt.sourceBoundAtEnd, cases: receipt.cases.length, checks: receipt.checks.length,
    partialAnalysis: receipt.cases[0]?.partialAnalysis?.status, externalRequests: receipt.externalRequests.length,
    errors: receipt.errors.length, artifacts}, null, 2));
}
