import assert from "node:assert/strict";
import {mkdtemp, readFile, writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join, resolve, extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";
import {testExportDiagnosticsOption, startExportDiagnostics} from "./export-diagnostics.mjs";
import {collectRunnerFacts} from "./runner-facts.mjs";
import {testAudioOutputOption, installTestAudioOutput, verifyTestAudioOutput} from "./export-audio-output.mjs";
import {exportSourceHashes} from "./export-source-binding.mjs";
import {installExportBackendObserver, exportBackendSnapshot} from "./export-backend-observer.mjs";

const {args: audioArgs, audioOutput} = testAudioOutputOption(process.argv.slice(2));
const {args, diagnostics} = testExportDiagnosticsOption(audioArgs, ["actual", "--before", "--fault=omit-readiness", "--validate-only"]);
assert(args.length <= 1, "Unknown startup test option");
const mode = args[0] ?? "actual";
assert(["actual", "--before", "--fault=omit-readiness", "--validate-only"].includes(mode));
const root = resolve(import.meta.dirname, "..");

function startupReadinessControl(before) {
  let pcmMatches = 0, recorderMatches = 0;
  return {name: "startup-causal-control", enforce: "pre",
    get pcmMatches() {return pcmMatches;},
    get recorderMatches() {return recorderMatches;},
    transform(code, id) {
      if (id.endsWith("/src/editor/export-pcm.ts") && !before) {
        const seam = "if (clock.read(now / 1000, audio.currentTime)) break;";
        assert.equal(code.split(seam).length, 2, "PCM readiness omission must match its actual sole admission");
        pcmMatches++;
        // Keep the actual getter side effect that begins the controlled hold.
        return code.replace(seam, "if ((audio.currentTime, true)) break;");
      }
      if (!id.endsWith("/src/editor/export.ts")) return;
      recorderMatches++;
      if (before) return before;
      const start = '        if (audio) await awaitAudioStartup(audio, renderSignal,', end = '          });';
      assert.equal(code.split(start).length, 2, "Readiness omission must match the actual first-start admission");
      const at = code.indexOf(start), finish = code.indexOf(end, at) + end.length;
      assert(finish > at); return code.slice(0, at) + "        // omitted startup readiness" + code.slice(finish);
    },
  };
}

if (mode === "--validate-only") {
  const pcm = await readFile(join(root, "src/editor/export-pcm.ts"), "utf8");
  const recorder = await readFile(join(root, "src/editor/export.ts"), "utf8");
  const control = startupReadinessControl();
  assert.equal(control.transform(pcm, "/unrelated.ts"), undefined);
  const changed = control.transform(pcm, "/src/editor/export-pcm.ts");
  const seam = "if (clock.read(now / 1000, audio.currentTime)) break;";
  assert.equal(changed, pcm.replace(seam, "if ((audio.currentTime, true)) break;"));
  assert.throws(() => startupReadinessControl().transform(pcm.replace(seam, ""), "/src/editor/export-pcm.ts"));
  assert.throws(() => startupReadinessControl().transform(pcm + "\n" + seam, "/src/editor/export-pcm.ts"));
  const legacyChanged = control.transform(recorder, "/src/editor/export.ts");
  const start = '        if (audio) await awaitAudioStartup(audio, renderSignal,', end = '          });';
  const at = recorder.indexOf(start), finish = recorder.indexOf(end, at) + end.length;
  assert.equal(legacyChanged, recorder.slice(0, at) + "        // omitted startup readiness" + recorder.slice(finish));
  assert.equal(control.pcmMatches, 1); assert.equal(control.recorderMatches, 1);
  const fixture = await readFile(join(root, "tests/export-startup-fixture.ts"), "utf8");
  const helperStart = fixture.indexOf("function startupClip("), helperEnd = fixture.indexOf("\n\n// Hold", helperStart);
  assert(helperStart >= 0 && helperEnd > helperStart);
  assert.equal(fixture.split("clips: [startupClip(local.source, fixture.extension)]").length, 2);
  const script = `import assert from "node:assert/strict";
    import {newDraft,validateDraft,timelineDuration} from "./src/editor/model";
    import {planExport} from "./src/editor/export-plan";
    import {pcmWindowMode} from "./src/editor/export-audio-route";
    ${fixture.slice(helperStart, helperEnd)}
    const source={name:"source.mp4",size:1024,lastModified:0,sha256:"a".repeat(64),kind:"video",width:640,height:360,duration:3};
    for(const extension of ["mp4","webm"]){
      const clip=startupClip({...source,duration:extension==="mp4"?3:1.5},extension);
      const draft=validateDraft({...newDraft(),ratio:"16:9",clips:[clip]});
      const plan=planExport(draft,true);
      assert.equal(timelineDuration(draft.clips),1.5);
      assert.equal(clip.speed,extension==="mp4"?2:1);
      assert.equal(plan.config.frames,45); assert.equal(plan.config.audioFrames,72000);
      assert.equal(pcmWindowMode(draft,clip,plan.windows[0],true,true),extension==="mp4"?"live":"offline");
    }`;
  const architecture = execFileSync(join(root, "node_modules/.bin/tsx"), ["--eval", script],
    {cwd: root, encoding: "utf8", timeout: 15_000});
  console.log(JSON.stringify({status: "startup-source-controls-passed", pcmOmissionRetainsActualGetter: true,
    recorderOmissionExact: true, actualFixtureHelperValidatedAgainstModelPlanAndRoute: true,
    mp4: {speed: 2, sourceSeconds: 3, outputSeconds: 1.5, route: "live"},
    webm: {speed: 1, sourceSeconds: 1.5, outputSeconds: 1.5, route: "offline"},
    architecture, browserExecuted: false, mediaGenerated: false}));
  process.exit(0);
}

const artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-startup-"));
const paths = ["src/editor/export.ts", "src/editor/recording-clock.ts", "src/editor/media.ts", "src/editor/model.ts",
  "tests/export-startup-fixture.ts", "tests/export-startup-fixture.html", "tests/export-startup-browser.mjs", "tests/native-trace-observer.mjs", "tests/runner-facts.mjs",
  "tests/export-diagnostics.mjs", "tests/scheduling-probe.mjs"];
const hashes = () => exportSourceHashes(root, [...paths, "tests/export-backend-observer.mjs"]);
const receipt = {status: "running", mode, audioOutput, diagnostics, sourceHashes: await hashes(), runnerFacts: collectRunnerFacts(), cases: [], checks: [], externalRequests: [], errors: [],
  proof: "Actual exportLocalVideo with native Web Audio, owned worker or offered recorder fallback, and decoded PCM. Explicit startup currentTime observation hold; native time retained independently. No claim to reproduce the hosted device cause."};
let browser, server, page;
let nativeTraceOwner;
// Native tracing is optional evidence, never an export pass/fail control.
// --diagnostics retains it for the actual first freeze/MP4 case only.
async function startNativeStartupTrace(context, page) {
  return startExportDiagnostics({diagnostics, context, page, native: {artifacts, syncId: "startup-freeze-mp4-before-click",
    rawFileName: "native-trace-freeze-mp4.raw.private.json", sourceHashes: receipt.sourceHashes, onFacts: facts => {receipt.nativeTrace = facts;}}});
}

try {
  const before = mode === "--before" ? await readFile(process.env.STARTUP_BEFORE_EXPORT, "utf8") : undefined;
  if (before) receipt.beforeSourceSHA256 = createHash("sha256").update(before).digest("hex");
  const dist = join(artifacts, "dist");
  const omission = startupReadinessControl(before);
  await build({configFile: false, root, publicDir: false, logLevel: "error",
    plugins: mode === "actual" ? [] : [omission],
    build: {outDir: dist, rollupOptions: {input: join(root, "tests/export-startup-fixture.html")}}});
  if (mode !== "actual") {
    assert.equal(omission.recorderMatches, 1);
    assert.equal(omission.pcmMatches, before ? 0 : 1);
  }
  server = createServer(async (req, res) => {
    const path = resolve(dist, `.${new URL(req.url, "http://localhost").pathname}`);
    if (!path.startsWith(dist + "/") || req.method !== "GET") return res.writeHead(400).end();
    try {res.setHeader("Content-Type", ({".html": "text/html", ".js": "application/javascript"})[extname(path)] ?? "application/octet-stream"); res.end(await readFile(path));}
    catch {res.writeHead(404).end();}
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  const sources = {};
  for (const [extension, speed] of [["mp4", 2], ["webm", 1]]) {
    const source = join(artifacts, `opening-middle-tail-${extension}.mp4`);
    execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", `color=c=green:s=640x360:r=30:d=${1.5 * speed}`,
      "-f", "lavfi", "-i", `sine=frequency=990:duration=${.12 * speed}`, "-f", "lavfi", "-i", `sine=frequency=440:duration=${1.08 * speed}`,
      "-f", "lavfi", "-i", `sine=frequency=660:duration=${.3 * speed}`, "-filter_complex", "[1:a][2:a][3:a]concat=n=3:v=0:a=1[a]",
      "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source]);
    sources[extension] = source;
  }
  browser = await chromium.launch({headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE});
  const context = await browser.newContext({serviceWorkers: "block", viewport: {width: 1000, height: 800}});
  await installTestAudioOutput(context, audioOutput);
  await installExportBackendObserver(context);
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin === origin && route.request().method() === "GET" || url.protocol === "blob:") return route.continue();
    receipt.externalRequests.push(url.href); return route.abort();
  });
  page = await context.newPage(); page.setDefaultTimeout(15000); page.on("pageerror", error => receipt.errors.push(error.message));
  const run = async (scenario, extension = "mp4") => {
    await page.goto(`${origin}/tests/export-startup-fixture.html`);
    await verifyTestAudioOutput(page, audioOutput);
    await page.getByLabel("Synthetic source").setInputFiles(sources[extension]);
    await page.evaluate(({scenario, extension}) => Object.assign(window.startupFixture, {mode: scenario, extension}), {scenario, extension});
    const nativeTrace = diagnostics.enabled && mode === "actual" && receipt.cases.length === 0 && scenario === "freeze" && extension === "mp4"
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
    const record = {scenario, extension, ...result, events, audioOutput: await verifyTestAudioOutput(page, audioOutput)}; delete record.base64; receipt.cases.push(record);
    record.backend = await exportBackendSnapshot(page);
    assert.equal(record.backend.terminations, record.backend.workers,
      "Every constructed encoder worker must terminate");
    const content = events.filter(event => event.kind.startsWith("user.") || event.kind === "recorder.start");
    assert.deepEqual(content.filter(event => event.held), [], "Content and recording must not start while startup clock is frozen");
    assert(result.tracks.length >= 1 && result.tracks.every(state => state === "ended"), "Every created audio/capture track must end");
    assert.equal(result.audioState, "closed", "The owned audio context must close");
    if (["permanent", "abort", "stale", "suspended"].includes(scenario)) {
      assert.equal(result.ok, false); assert.equal(result.base64, undefined); assert.equal(content.length, 0);
      assert.deepEqual(result.trackKinds, ["audio"], "A pre-capture refusal creates only the owned audio destination");
      assert.deepEqual(events.filter(event => event.kind === "capture.create" || event.kind === "recorder.construct"), [],
        "Refused readiness must create no canvas capture track or recorder");
      assert.equal(record.backend.postedVideoInputs, 0); assert.equal(record.backend.postedAudioInputs, 0);
      assert.match(result.error, ({permanent: /Audio did not begin advancing/, abort: /Fixture startup cancelled/, stale: /edit changed/, suspended: /Audio stopped/})[scenario]);
      return;
    }
    assert.equal(result.ok, true, result.error);
    const worker = record.backend.postedVideoInputs > 0;
    if (mode !== "--before") assert.equal(worker, extension === "mp4",
      "The MP4 startup proof requires the actual worker/live path; WebM retains the recorder path");
    record.backendCoverage = worker ? "actual owned worker" : "actual recorder";
    if (worker) {
      assert.equal(record.backend.recorderConstructions, 0);
      assert.deepEqual(result.trackKinds, ["audio"], "Worker export retains its owned audio sink without canvas capture tracks");
      assert.equal(record.backend.postedVideoInputs, 45);
      assert.equal(record.backend.postedAudioFrames, 72_000);
      assert.equal(record.backend.postedAudioInputs, 71);
      assert.equal(record.backend.workletNodes, 1);
      assert.equal(record.backend.workletModuleCalls, 1);
      assert.equal(record.backend.workletModuleFulfilled, 1);
      assert.equal(record.backend.workletModuleRejected, 0);
      assert.equal(record.backend.workletPortCloses, 1);
      assert.equal(record.backend.workletDisconnects, 1);
      assert.deepEqual(record.backend.pcmWindowEvents.map(row => [row.type, row.windowIndex, row.outputBase]),
        [["armed", 0, 0], ["done", 0, 0]], "MP4 startup must exercise actual live capture");
      assert.equal(content.filter(event => event.kind === "user.video.play").length, 2,
        "Live MP4 primes and then plays the same pitch-preserving source");
      assert.equal(content.filter(event => event.kind === "user.buffer.start").length, 0);
    } else {
      assert.deepEqual([...result.trackKinds].sort(), ["audio", "video"], "Recorder retains both real capture tracks");
      assert.equal(content.filter(event => event.kind === "recorder.start").length, 1);
      assert.equal(content.filter(event => event.kind === "user.buffer.start").length, 1);
    }
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
    if (worker) {
      assert.equal(capture.length, 0); assert.equal(constructed.length, 0);
      const released = events.find(event => event.kind === "startup.released");
      const source = events.find(event => event.kind === "user.video.play");
      assert(released && source && source.wall >= released.wall,
        "Actual user sound must start only after startup release");
    } else {
    assert.equal(capture.length, 1); assert.equal(constructed.length, 1);
    const released = events.find(event => event.kind === "startup.released"), start = events.find(event => event.kind === "recorder.start");
    assert(released && start && capture[0].wall >= released.wall && constructed[0].wall >= capture[0].wall && start.wall >= constructed[0].wall,
      "Fresh capture and recorder must be constructed after startup release and before recording starts");
    }
  };
  await run("freeze"); receipt.checks.push("A held observed running clock permits no content/recorder start; actual2x live MP4 retains opening, middle and tail PCM with exact planned duration");
  await run("freeze", "webm"); receipt.checks.push("The same startup admits an offered WebM without awaiting its start event or losing original PCM");
  for (const scenario of ["permanent", "abort", "stale", "suspended"]) await run(scenario);
  receipt.checks.push("Persistent freeze, cancellation, stale edit and native suspension all refuse before recording/playback and clean every track/context");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = String(error.stack ?? error); process.exitCode = 1;
  if (page) {
    receipt.failureSnapshot = await page.evaluate(() => ({events: window.startupFixture?.events, result: window.startupFixture?.result})).catch(() => null);
    receipt.failureBackend = await exportBackendSnapshot(page).catch(() => null);
  }
}
finally {
  if (nativeTraceOwner) await nativeTraceOwner.finish();
  await browser?.close(); if (server) await new Promise(done => server.close(done));
  receipt.sourceBoundAtEnd = JSON.stringify(await hashes()) === JSON.stringify(receipt.sourceHashes);
  if (!receipt.sourceBoundAtEnd) {receipt.status = "failed"; process.exitCode = 1;}
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({...receipt, artifacts}, null, 2));
}
