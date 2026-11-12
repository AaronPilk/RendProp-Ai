/* Root-owned actual browser/codec runner. --validate-only starts no media. */
import assert from "node:assert/strict";
import {execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import {createServer} from "node:http";
import {mkdtemp, readFile, readdir, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {extname, join, resolve} from "node:path";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";
import {generateExportMedia} from "./export-webcodecs-media.mjs";
import {verifyCombinedOutput, verifyAuxiliaryOutput, verifySeekOutput, verifyHybridReuseOutput} from "./export-webcodecs-oracles.mjs";
import {exportSourceHashes} from "./export-source-binding.mjs";
import {installExportBackendObserver, exportBackendSnapshot, simulatedUnsupportedEncoderPlugin,
  simulatedFinalizeHangPlugin, reducedOutputCapacityPlugin} from "./export-backend-observer.mjs";
import {testAudioOutputOption, installTestAudioOutput, verifyTestAudioOutput} from "./export-audio-output.mjs";
import {collectRunnerFacts} from "./runner-facts.mjs";

const {args, audioOutput} = testAudioOutputOption(process.argv.slice(2));
const permitted = ["--validate-only", "--long-only", "--lifecycle-only", "--simulated-unsupported",
  "--finalize-cancel-control", "--output-limit-control", "--healthy-only", "--seek-only", "--hybrid-reuse-only", "--fractional-only"];
assert(args.every(value => permitted.includes(value)) && args.length <= 1, "Unknown integrated export option");
const mode = args[0] ?? "actual";
const root = resolve(import.meta.dirname, "..");
const testPaths = ["tests/export-webcodecs-browser.mjs", "tests/export-webcodecs-fixture.ts",
  "tests/export-webcodecs-fixture.html", "tests/export-webcodecs-draft.ts", "tests/export-webcodecs-metadata.test.ts",
  "tests/export-webcodecs-oracles.mjs", "tests/export-webcodecs-media.mjs",
  "tests/export-backend-observer.mjs", "tests/export-browser-controls.test.mjs", "tests/export-audio-output.mjs", "tests/finishing-audio-probe.mjs",
  "tests/runner-facts.mjs"];
const hashes = () => exportSourceHashes(root, testPaths);
if (mode === "--validate-only") {
  const controls = execFileSync(process.execPath, ["--test", "tests/export-browser-controls.test.mjs"],
    {cwd: root, encoding: "utf8", timeout: 15_000});
  const output = execFileSync(join(root, "node_modules/.bin/tsx"),
    ["--test", "tests/export-webcodecs-metadata.test.ts"], {cwd: root, encoding: "utf8", timeout: 15_000});
  const bound = await hashes();
  console.log(JSON.stringify({status: "static-metadata-and-source-inventory-passed",
    sourceHashes: bound, metadataGate: output, sourceControls: controls,
    browserExecuted: false, mediaGenerated: false}));
  process.exit(0);
}

const artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-webcodecs-")), dist = join(artifacts, "dist");
const receipt = {status: "running", mode, audioOutput, sourceHashesBefore: await hashes(),
  sourceHashesAfter: null, sourceBoundAtEnd: false, runnerFacts: collectRunnerFacts(),
  proof: "Actual exportLocalVideo with synthetic converted/tagged media and decoded MP4/PCM/pixels. No live account, provider or whole-release claim.",
  capabilityOverride: mode === "--simulated-unsupported" ? "Test-only false capability response; not evidence this browser actually lacks support." : null,
  lifecycleOverride: mode === "--finalize-cancel-control" ? "Test-only finalization-boundary hold on the existing muted-music AAC/H264 edit; real worker termination is exercised. This does not test a real codec hang or resolve the separately retained live-clock finding." : null,
  capacityOverride: mode === "--output-limit-control" ? "Test-only worker output ceiling 256 bytes; production 128 MiB remains unchanged." : null,
  sourceFiles: {}, builtAssets: {}, cases: [], checks: [], errors: [], externalRequests: []};
let browser, server, page;
const persist = () => writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
try {
  const unsupported = simulatedUnsupportedEncoderPlugin();
  const finalizeHang = simulatedFinalizeHangPlugin(), outputLimit = reducedOutputCapacityPlugin();
  await build({configFile: false, root, publicDir: false, logLevel: "error",
    worker: {plugins: () => mode === "--simulated-unsupported" ? [unsupported] :
      mode === "--finalize-cancel-control" ? [finalizeHang] :
      mode === "--output-limit-control" ? [outputLimit] : []},
    build: {outDir: dist, rollupOptions: {input: join(root, "tests/export-webcodecs-fixture.html")}}});
  if (mode === "--simulated-unsupported") assert.equal(unsupported.matchedSourceCount, 1,
    "Simulated capability response did not compile the exact worker admission");
  if (mode === "--finalize-cancel-control") assert.equal(finalizeHang.matchedSourceCount, 1);
  if (mode === "--output-limit-control") assert.equal(outputLimit.matchedSourceCount, 1);
  const visit = async (directory, prefix = "") => {
    for (const row of await readdir(directory, {withFileTypes: true})) {
      const relative = prefix ? prefix + "/" + row.name : row.name, path = join(directory, row.name);
      if (row.isDirectory()) await visit(path, relative);
      else receipt.builtAssets[relative] = createHash("sha256").update(await readFile(path)).digest("hex");
    }
  };
  await visit(dist);
  server = createServer(async (request, response) => {
    const path = resolve(dist, "." + new URL(request.url, "http://localhost").pathname);
    if (!path.startsWith(dist + "/") || request.method !== "GET") return response.writeHead(400).end();
    try {
      response.setHeader("Content-Type", ({".html": "text/html", ".js": "application/javascript"})[extname(path)] ?? "application/octet-stream");
      response.end(await readFile(path));
    } catch {response.writeHead(404).end();}
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done));
  const origin = "http://127.0.0.1:" + server.address().port;
  const generated = await generateExportMedia(artifacts, {seekOnly: mode === "--seek-only",
    hybridReuseOnly: mode === "--hybrid-reuse-only"});
  receipt.sourceFiles = generated.sources;
  receipt.runtime = {node: process.version,
    ffmpeg: execFileSync("ffmpeg", ["-version"], {encoding: "utf8", timeout: 10_000}).split("\n")[0],
    ffprobe: execFileSync("ffprobe", ["-version"], {encoding: "utf8", timeout: 10_000}).split("\n")[0]};
  browser = await chromium.launch({headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE});
  receipt.browserVersion = browser.version();

  const prepare = async (scenario, fault = "none") => {
    const context = await browser.newContext({serviceWorkers: "block", acceptDownloads: true,
      viewport: {width: 1440, height: 1100}});
    await installTestAudioOutput(context, audioOutput); await installExportBackendObserver(context);
    await context.route("**/*", route => {
      const url = new URL(route.request().url());
      if (url.origin === origin && route.request().method() === "GET" || url.protocol === "blob:")
        return route.continue();
      receipt.externalRequests.push(url.href); return route.abort();
    });
    page = await context.newPage(); page.setDefaultTimeout(15_000);
    page.on("pageerror", error => receipt.errors.push(error.message));
    await page.goto(origin + "/tests/export-webcodecs-fixture.html");
    await verifyTestAudioOutput(page, audioOutput);
    await page.evaluate(({scenario, fault}) =>
      Object.assign(window.exportWebCodecsFixture, {scenario, fault}), {scenario, fault});
    for (const [id, path] of Object.entries(generated.assets)) await page.locator("#" + id).setInputFiles(path);
    await page.getByRole("button", {name: "Prepare integrated files", exact: true}).click();
    await page.waitForFunction(() => window.exportWebCodecsFixture.prepared ||
      window.exportWebCodecsFixture.settled);
    const setup = await page.evaluate(() => ({prepared: window.exportWebCodecsFixture.prepared,
      error: window.exportWebCodecsFixture.result, seconds: window.exportWebCodecsFixture.plannedSeconds}));
    assert(setup.prepared, "Actual model/inspection preparation failed: " + JSON.stringify(setup));
    return {context, setup};
  };
  const finish = async (scenario, fault, context, setup) => {
    await page.getByRole("button", {name: "Export integrated video", exact: true}).click();
    await expect.poll(() => page.evaluate(() => window.exportWebCodecsFixture.settled),
      {timeout: scenario === "long" ? 420_000 : 45_000}).toBe(true);
    const state = await page.evaluate(() => {
      const {result, injected, injectionEvidence, revision} = window.exportWebCodecsFixture;
      const link = document.querySelector("#download");
      return {result, injected, injectionEvidence, revision, playEvidence: window.exportPlayEvidence,
        downloadHidden: link.hidden, hasDownloadHref: link.hasAttribute("href")};
    });
    const backend = await exportBackendSnapshot(page);
    const row = {scenario, fault, plannedSeconds: setup.seconds, ...state, backend};
    receipt.cases.push(row); await persist();
    assert(backend.contextStates.every(value => value === "closed"), "Every actual AudioContext must close");
    assert(backend.trackStates.every(value => value === "ended"), "Every owned audio/capture track must end");
    assert.equal(backend.terminations, backend.workers, "Every constructed worker must terminate once");
    assert(backend.maximumPendingVideo <= 2 && backend.maximumPendingAudio <= 8,
      "Actual worker inputs exceeded owned finite credits");
    assert.equal(backend.workletLifetimes.length, backend.workletNodes);
    assert(backend.workletLifetimes.every(value => value.portCloses === 1 && value.disconnects === 1),
      "Each actual PCM tap must close its own port and disconnect once");
    return row;
  };
  const positives = mode === "--long-only" ? [["long", "none"]] :
    mode === "--seek-only" ? [["seek", "none"]] :
    mode === "--hybrid-reuse-only" ? [["hybrid-reuse", "none"]] :
    mode === "--fractional-only" ? [["fractional", "none"]] :
    mode === "--healthy-only" ? [["combined", "none"]] :
    ["--lifecycle-only", "--finalize-cancel-control", "--output-limit-control"].includes(mode) ? [] :
    mode === "--simulated-unsupported" ? [["silent", "none"]] :
    [["combined", "none"], ["combined", "late-play-promise"],
      ["fractional", "none"], ["muted-music", "none"], ["silent", "none"]];
  for (const [scenario, fault] of positives) {
    const {context, setup} = await prepare(scenario, fault);
    try {
      const row = await finish(scenario, fault, context, setup);
      assert.equal(row.result?.ok, true, row.result?.error);
      const download = page.waitForEvent("download"); await page.locator("#download").click();
      const file = join(artifacts, scenario + "-" + fault + ".mp4"); await (await download).saveAs(file);
      row.output = {file, sha256: createHash("sha256").update(await readFile(file)).digest("hex")};
      if (mode === "--simulated-unsupported") {
        assert(row.backend.unsupportedReplies > 0 && row.backend.recorderConstructions === 1,
          "Simulated unsupported response must enter the actual recorder fallback");
        assert.equal(row.backend.postedVideoInputs, 0); assert.equal(row.backend.postedAudioInputs, 0);
        const metadata = JSON.parse(execFileSync("ffprobe",
          ["-v", "error", "-show_streams", "-show_format", "-of", "json", file], {encoding: "utf8", timeout: 30_000}));
        assert.equal(metadata.streams.filter(value => value.codec_type === "video" && value.codec_name === "h264").length, 1);
        assert.equal(metadata.streams.filter(value => value.codec_type === "audio").length, 0);
        assert(Math.abs(Number(metadata.format.duration) - 1.2) < .18);
        row.output.legacyMetadata = metadata; row.coverage = "simulated-capability-response legacy fallback only";
      } else {
        assert.equal(row.backend.recorderConstructions, 0, "Worker gate must not count recorder fallback");
        assert.equal(row.backend.unsupportedReplies, 0);
        assert.equal(row.backend.postedVideoInputs, Math.ceil(Math.round(setup.seconds * 1e6) * 30 / 1e6));
        const withAudio = !["silent", "long", "seek"].includes(scenario);
        assert.equal(row.backend.postedAudioFrames, withAudio ? Math.round(setup.seconds * 48_000) : 0);
        assert.equal(row.backend.contexts, withAudio ? 1 : 0, "No-audio exports must not require AudioContext");
        if (scenario === "combined") {
          assert.equal(row.backend.postedAudioInputs, 260, "All five exact PCM windows must reach the encoder");
          assert.deepEqual(row.backend.pcmWindowEvents.map(value => [value.type, value.windowIndex, value.outputBase]),
            [["armed", 1, 24_000], ["done", 1, 24_000]], "Only the2× original source may use live capture");
          assert.deepEqual(row.backend.pcmWindowEvents.filter(value => value.type === "done")
            .map(value => [value.windowIndex, value.frames, value.blocks]),
          [[1, 96_000, 94]]);
          assert.equal(row.backend.workletNodes, 1);
        }
        if (["combined", "hybrid-reuse"].includes(scenario)) {
          assert.equal(row.backend.workletModuleCalls, 1); assert.equal(row.backend.workletModuleFulfilled, 1);
          assert.equal(row.backend.workletModuleRejected, 0);
          assert.equal(row.backend.trackStates.length, 1, "Live windows must reuse the one owned bootstrap sink");
        }
        if (scenario === "hybrid-reuse") {
          assert.equal(row.backend.postedAudioInputs, 72);
          assert.equal(row.backend.workletNodes, 2);
          assert.deepEqual(row.backend.pcmWindowEvents.map(value => [value.type, value.windowIndex, value.outputBase]),
            [["armed", 0, 0], ["done", 0, 0], ["armed", 2, 48_000], ["done", 2, 48_000]]);
          assert.deepEqual(row.backend.pcmWindowEvents.filter(value => value.type === "done")
            .map(value => [value.frames, value.blocks]), [[24_000, 24], [24_000, 24]]);
        }
        if (scenario === "seek") {
          assert.equal(row.backend.postedAudioInputs, 0); assert.equal(row.backend.playCalls, 0);
          row.output.oracles = verifySeekOutput(file, generated.sources.sourceSeek.seekProbe);
        } else if (scenario === "hybrid-reuse") row.output.oracles = verifyHybridReuseOutput(file);
        else row.output.oracles = scenario === "combined" ? verifyCombinedOutput(file) : verifyAuxiliaryOutput(file, scenario);
        row.coverage = "actual shipping entry with owned worker";
        if (fault === "late-play-promise") {
          assert.equal(row.injected, true);
          assert.equal(row.injectionEvidence?.workletPhase, "armed");
          assert.equal(row.injectionEvidence?.windowIndex, 1);
          assert.equal(row.injectionEvidence?.outputBase, 24_000);
          const first = row.playEvidence.find(value => value.phase === "call"),
            last = row.playEvidence.find(value => value.phase === "delayed-promise-resolved");
          assert(first && last && last.sourceSeconds - first.sourceSeconds > .15,
            "The source must actually advance while only promise delivery is delayed");
        }
      }
      receipt.checks.push(scenario + ": decoded media and exact ownership passed"); await persist();
    } finally {await context.close();}
  }
  if (["--finalize-cancel-control", "--output-limit-control"].includes(mode)) {
    const fault = mode === "--finalize-cancel-control" ? "cancel-finalize" : "output-limit";
    const scenario = mode === "--finalize-cancel-control" ? "muted-music" : "silent";
    const {context, setup} = await prepare(scenario, fault);
    let downloads = 0;
    const observeDownload = () => {downloads++;};
    if (fault === "cancel-finalize") page.on("download", observeDownload);
    try {
      const row = await finish(scenario, fault, context, setup);
      assert.equal(row.injected, true); assert.equal(row.result?.ok, false);
      assert(row.downloadHidden && !row.hasDownloadHref);
      assert.equal(row.backend.recorderConstructions, 0, "A terminal content/output error must not retry through recorder");
      if (fault === "cancel-finalize") {
        assert.match(row.result.error, /Synthetic finalization cancellation/);
        assert.equal(row.injectionEvidence.type, "test-only.finalize-entered");
        assert.equal(row.backend.postedEndInputs, 1);
        assert.equal(row.backend.postedVideoInputs, 31);
        assert.equal(row.backend.postedAudioFrames, 48_816);
        assert.equal(row.backend.postedAudioInputs, 48);
        assert.deepEqual(row.backend.workerConfigs, [{width: 960, height: 960,
          frames: 31, durationMicroseconds: 1_017_000, withAudio: true,
          audioFrames: 48_816, windowFrameCounts: [48_816],
          frameRate: 30, sampleRate: 48_000, channels: 2}]);
        assert.equal(row.backend.workers, 1); assert.equal(row.backend.terminations, 1);
        assert.equal(row.backend.dropped, 0, "Finalization ordering evidence must be complete");
        const events = row.backend.events;
        const probes = events.flatMap((value, index) => value.kind === "test-only.finalize-entered" ? [index] : []);
        assert.equal(probes.length, 1, "Only the actual worker boundary may trigger cancellation");
        const beforeProbe = events.slice(0, probes[0]);
        const video = beforeProbe.filter(value => value.kind === "worker.input" && value.type === "video");
        const audio = beforeProbe.filter(value => value.kind === "worker.input" && value.type === "audio");
        const ends = beforeProbe.flatMap((value, index) => value.kind === "worker.input" && value.type === "end" ? [index] : []);
        assert.deepEqual(video.map(value => value.sequence), Array.from({length: 31}, (_, index) => index));
        assert.deepEqual(audio.map(value => value.sequence), Array.from({length: 48}, (_, index) => index));
        assert.equal(audio.reduce((sum, value) => sum + value.frameCount, 0), 48_816);
        assert.equal(ends.length, 1);
        assert(beforeProbe.findLastIndex(value => value.kind === "worker.input" && ["audio", "video"].includes(value.type)) < ends[0],
          "All real media inputs must precede the sole end message and finalization probe");
        assert.equal(beforeProbe.filter(value => value.kind === "worker.reply" && value.type === "ack").length, 79);
        assert(events.findIndex(value => value.kind === "worker.terminate") > probes[0],
          "Cancellation must terminate the real worker after its finalization boundary");
        assert.equal(downloads, 0, "Finalization cancellation must offer no browser download");
        const sourcePaths = new Set(Object.values(generated.sources).map(value => resolve(value.file)));
        assert.deepEqual((await readdir(artifacts, {withFileTypes: true}))
          .filter(value => value.isFile() && /\.(mp4|webm)$/.test(value.name) && !sourcePaths.has(resolve(artifacts, value.name)))
          .map(value => value.name), [], "Finalization cancellation must retain no output file");
      } else {
        assert.match(row.result.error, /exceeds 128 MiB/);
        assert(row.backend.postedVideoInputs > 0);
      }
      receipt.checks.push(fault + ": clearly labeled simulated boundary refused with real ownership cleanup");
    } finally {
      if (fault === "cancel-finalize") page.off("download", observeDownload);
      await context.close();
    }
  }
  if (mode === "actual" || mode === "--lifecycle-only") {
    const refusals = [
      ["missing-source", /Reselect .*before exporting/i],
      ["music-mismatch", /music.*(match|changed)/i],
      ["narration-invalid", /narration|Unable to decode audio data|EncodingError/i],
      ["cancel-before", /Synthetic pre-export cancellation/],
      ["cancel-second-window", /Synthetic second-window cancellation/],
      ["revision-second-window", /edit changed|revision changed/i],
      ["suspend-second-window", /Audio stopped|timing drifted|suspended/i],
      ["cancel-frame", /Synthetic frame cancellation/],
      ["worker-post-failure", /Synthetic worker post failure/],
      ["delay-native-play", /Original audio playback stalled|Original audio stalled/i],
    ];
    for (const [fault, reason] of refusals) {
      const {context, setup} = await prepare("combined", fault);
      try {
        const row = await finish("combined", fault, context, setup);
        assert.equal(row.injected, true, "Named fault was not actually injected: " + fault);
        assert.equal(row.result?.ok, false, "Named fault unexpectedly offered output: " + fault);
        assert.match(row.result.error, reason);
        assert(row.downloadHidden && !row.hasDownloadHref, "Refusal must expose no partial download");
        if (["cancel-second-window", "revision-second-window", "suspend-second-window"].includes(fault)) {
          assert(row.injectionEvidence.type === "audio" && row.injectionEvidence.startFrame >= 24_000);
          assert.equal(row.injectionEvidence.workletPhase, "armed");
          assert.equal(row.injectionEvidence.windowIndex, 1);
          assert.equal(row.injectionEvidence.outputBase, 24_000);
        }
        if (["cancel-frame", "worker-post-failure"].includes(fault))
          assert(row.injectionEvidence.type === "video" && row.injectionEvidence.sequence >= 4);
        if (fault === "delay-native-play") {
          assert.equal(row.injectionEvidence?.workletPhase, "armed");
          assert.equal(row.injectionEvidence?.windowIndex, 1);
          assert.equal(row.injectionEvidence?.outputBase, 24_000);
        }
        if (["missing-source", "cancel-before"].includes(fault)) {
          assert.equal(row.backend.contexts, 0); assert.equal(row.backend.contentStarts, 0);
          assert.equal(row.backend.workers, 0);
        }
        receipt.checks.push(fault + ": actual intended refusal, cleanup and no download"); await persist();
      } finally {await context.close();}
    }
  }
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []);
  receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = error.stack ?? String(error); process.exitCode = 1;
  if (page) receipt.failureSnapshot = await page.evaluate(() => ({
    fixture: window.exportWebCodecsFixture ? {...window.exportWebCodecsFixture, controller: undefined} : null,
    backend: window.exportBackendObservation,
  })).catch(() => null);
} finally {
  await browser?.close(); if (server) await new Promise(done => server.close(done));
  receipt.sourceHashesAfter = await hashes();
  receipt.sourceBoundAtEnd = JSON.stringify(receipt.sourceHashesBefore) === JSON.stringify(receipt.sourceHashesAfter);
  if (!receipt.sourceBoundAtEnd) {receipt.status = "failed"; process.exitCode = 1;}
  await persist(); console.log(JSON.stringify({status: receipt.status, mode, artifacts,
    receipt: join(artifacts, "receipt.json"), checks: receipt.checks.length}));
}
