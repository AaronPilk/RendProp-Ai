import assert from "node:assert/strict";
import {mkdtemp, readFile, writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join, resolve, extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";

const mode = process.argv[2] ?? "actual";
assert(["actual", "--before", "--fault=omit-readiness"].includes(mode));
const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-startup-"));
const paths = ["src/editor/export.ts", "src/editor/recording-clock.ts", "src/editor/media.ts", "src/editor/model.ts",
  "tests/export-startup-fixture.ts", "tests/export-startup-fixture.html", "tests/export-startup-browser.mjs"];
const hashes = async () => Object.fromEntries(await Promise.all(paths.map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = {status: "running", mode, sourceHashes: await hashes(), cases: [], checks: [], externalRequests: [], errors: [],
  proof: "Native Web Audio/canvas/MediaRecorder and decoded PCM. Explicit startup currentTime observation hold; real native time retained independently. No claim to reproduce the underlying hosted browser/device cause."};
let browser, server, page, mutated = false;
let nativeTraceOwner;
// Passive native tracing for the actual first freeze/MP4 case only. This owns
// no product clock/source/graph and never turns an export refusal into success.
async function startNativeStartupTrace(context, page) {
  const categories = ["webaudio", "disabled-by-default-webaudio.audionode"];
  const names = ["AudioDestination::RequestRender", "RealtimeAudioDestinationHandler::Render", "MediaStreamAudioDestinationHandler::Process"];
  const limits = {bufferKiB: 1024, rawBytes: 2 * 1024 * 1024, events: 10000, captureMs: 20000, finishMs: 10000};
  const facts = {status: "initializing", passiveOnly: true, observationMayPerturbTiming: true,
    categories, requiredSpanNames: names, limits, issues: [], sourceHashes: {...receipt.sourceHashes}};
  receipt.nativeTrace = facts;
  let session, attempted = false, started = false, timer, completeEvent, completeResolve, ending, finishing, stream;
  const completed = new Promise(resolve => {completeResolve = resolve;});
  const bounded = async (promise, ms) => {
    let timeout;
    try {return await Promise.race([promise, new Promise((_, reject) => {timeout = setTimeout(() => reject(new Error("Native trace observation deadline")), Math.max(1, ms));})]);}
    finally {clearTimeout(timeout);}
  };
  // Never persist protocol error text, trace arguments or device identifiers in
  // the receipt. Raw bytes use a bounded owned 0600 local file; current CI
  // artifact patterns do not upload it. No screenshots, network, stack
  // sampling, system tracing or arbitrary categories are enabled.
  const issue = (stage, error) => {if (facts.issues.length < 8) facts.issues.push({stage, errorClass: error?.name ?? "Error"});};
  const endOnce = reason => {
    if (!ending) {facts.stopReason = reason; ending = bounded(session.send("Tracing.end"), 2500).catch(error => issue("end", error));}
    return ending;
  };
  const finish = () => finishing ??= (async () => {
    clearTimeout(timer);
    const deadline = Date.now() + limits.finishMs;
    const remaining = () => Math.max(1, deadline - Date.now());
    try {
      if (attempted) await endOnce("case-finished");
      if (!started) return;
      completeEvent = await bounded(completed, remaining()); stream = completeEvent.stream;
      facts.dataLossOccurred = completeEvent.dataLossOccurred;
      if (typeof facts.dataLossOccurred !== "boolean" || typeof stream !== "string" || !stream || completeEvent.traceFormat !== "json" || completeEvent.streamCompression && completeEvent.streamCompression !== "none") {
        facts.status = "unavailable-stream-format"; return;
      }
      // No stream retrieval, JSON parsing or disk serialization happens until
      // the first case has produced its result (or its original poll failed).
      const chunks = []; let bytes = 0, eof = false, reads = 0;
      while (!eof) {
        if (Date.now() >= deadline) throw new Error("Native trace drain deadline");
        if (++reads > 40) throw new Error("Native trace chunk limit");
        const part = await bounded(session.send("IO.read", {handle: stream, size: 65536}), remaining());
        const data = Buffer.from(part.data, part.base64Encoded ? "base64" : "utf8");
        if (!data.length && part.eof !== true) throw new Error("Native trace made no progress");
        const room = limits.rawBytes - bytes;
        chunks.push(data.subarray(0, room)); bytes += Math.min(room, data.length); eof = part.eof === true;
        if (data.length > room || bytes === limits.rawBytes && !eof) {facts.rawByteLimitReached = true; break;}
      }
      const raw = Buffer.concat(chunks, bytes), path = join(artifacts, "native-trace-freeze-mp4.raw.private.json");
      await writeFile(path, raw, {flag: "wx", mode: 0o600});
      facts.raw = {path, bytes, sha256: createHash("sha256").update(raw).digest("hex"), completeStream: eof};
      if (!eof) {facts.status = "incomplete-byte-limit"; return;}
      const parsed = JSON.parse(raw.toString("utf8"));
      if (!Array.isArray(parsed.traceEvents)) {facts.status = "unavailable-event-shape"; return;}
      // BEGIN pure native trace projection
      facts.eventCount = parsed.traceEvents.length;
      if (facts.eventCount > limits.events) {facts.status = "incomplete-event-limit"; return;}
      const markers = parsed.traceEvents.filter(event => event.name === "clock_sync" &&
        event.args?.sync_id === "startup-freeze-mp4-before-click" && Number.isFinite(event.ts));
      const bridge = facts.clockMarker, maximumBracketMs = 2 * 1000 / 30;
      const bracketValid = bridge && Number.isFinite(bridge.pageWallBeforeMs) && Number.isFinite(bridge.pageWallAfterMs) &&
        bridge.pageWallAfterMs >= bridge.pageWallBeforeMs;
      facts.clockAlignment = {matchedMarkers: markers.length,
        available: markers.length === 1 && !!bracketValid && bridge.pageWallAfterMs - bridge.pageWallBeforeMs <= maximumBracketMs,
        maximumBracketMs, ...(bracketValid ? {pageWallBeforeMs: bridge.pageWallBeforeMs, pageWallAfterMs: bridge.pageWallAfterMs,
          uncertaintyMs: bridge.pageWallAfterMs - bridge.pageWallBeforeMs} : {}),
        ...(markers.length === 1 ? {traceMarkerUs: markers[0].ts} : {})};
      const spans = [], stacks = new Map();
      for (const event of [...parsed.traceEvents].sort((a, b) => a.ts - b.ts)) {
        if (!Number.isFinite(event.ts) || !Number.isInteger(event.pid) || !Number.isInteger(event.tid)) continue;
        const key = `${event.pid}:${event.tid}`, stack = stacks.get(key) ?? [];
        const add = (first, end) => {if (names.includes(first.name) && Number.isFinite(end) && end >= first.ts) spans.push({name: first.name, pid: first.pid, tid: first.tid, startUs: first.ts, durationUs: end - first.ts});};
        if (event.ph === "B") {stack.push(event); stacks.set(key, stack);}
        else if (event.ph === "E") {const first = stack.pop(); if (first) add(first, event.ts);}
        else if (event.ph === "X" && Number.isFinite(event.dur)) add(event, event.ts + event.dur);
      }
      facts.spans = spans;
      facts.spanCounts = Object.fromEntries(names.map(name => [name, spans.filter(span => span.name === name).length]));
      facts.unmatchedRequiredBegins = [...stacks.values()].flat().filter(event => names.includes(event.name)).length;
      facts.status = facts.dataLossOccurred !== false || facts.stopReason !== "case-finished" || !facts.clockAlignment.available || facts.unmatchedRequiredBegins ||
        names.some(name => !facts.spanCounts[name]) ? "captured-incomplete" : "captured-required-spans";
      facts.causalConclusion = "UNKNOWN: native spans require time-aligned offline review; a passing export is not a plateau repair";
      // END pure native trace projection
    } catch (error) {issue("finish", error); facts.status = "unavailable-or-incomplete";}
    finally {
      if (stream) await bounded(session.send("IO.close", {handle: stream}), 1000).catch(error => issue("stream-close", error));
      if (session) await bounded(session.detach(), 1500).catch(error => issue("detach", error));
    }
  })();
  try {
    session = await bounded(context.newCDPSession(page), 2500);
    session.on("Tracing.tracingComplete", value => {completeEvent = value; completeResolve(value);});
    session.on("Tracing.bufferUsage", value => {
      const fullness = Math.max(value.percentFull ?? 0, value.value ?? 0);
      facts.maximumBufferFullness = Math.max(facts.maximumBufferFullness ?? 0, fullness);
      if (fullness >= .8 || (value.eventCount ?? 0) >= limits.events) void endOnce("buffer-or-event-budget");
    });
    const available = await bounded(session.send("Tracing.getCategories"), 2500);
    facts.categorySupport = Object.fromEntries(categories.map(category => [category, available.categories.includes(category)]));
    if (categories.some(category => !facts.categorySupport[category])) {facts.status = "unavailable-required-category"; return {finish};}
    attempted = true;
    await bounded(session.send("Tracing.start", {transferMode: "ReturnAsStream", streamFormat: "json", streamCompression: "none",
      bufferUsageReportingInterval: 100, traceConfig: {recordMode: "recordUntilFull", traceBufferSizeInKb: limits.bufferKiB,
        enableSampling: false, enableSystrace: false, enableArgumentFilter: true, includedCategories: categories}}), 2500);
    started = true; facts.status = "recording";
    timer = setTimeout(() => {void endOnce("capture-deadline");}, limits.captureMs);
    // The bracket maps the trace marker to page wall time without rewriting
    // either clock. Unsupported markers remain explicitly unavailable.
    try {
      const syncId = "startup-freeze-mp4-before-click";
      const before = await bounded(page.evaluate(() => performance.now()), 1000);
      await bounded(session.send("Tracing.recordClockSyncMarker", {syncId}), 1000);
      const after = await bounded(page.evaluate(() => performance.now()), 1000);
      facts.clockMarker = {syncId, pageWallBeforeMs: before, pageWallAfterMs: after, exactMappingClaim: false};
    } catch (error) {issue("clock-marker", error);}
  } catch (error) {issue("start", error); facts.status = "unavailable-start";}
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
