/* External, partial three-second proof. Never run from the shipping checkout. */
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {createServer} from "node:http";
import {mkdtemp, readFile, readdir, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {dirname, extname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {build} from "vite";
import {chromium, expect} from "@playwright/test";

const root = fileURLToPath(new URL("../", import.meta.url));
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-audible-webcodecs-"));
const dist = join(artifacts, "dist");
const entry = process.env.AUDIBLE_PROOF_MEDIABUNNY_ENTRY;
const browserPath = process.env.STUDIO_BROWSER_EXECUTABLE;
const runtimeProfile = process.argv.includes("--local-observation") ?
  "local-observation" : "hosted-exact";
const packageRoot = entry && resolve(dirname(entry), "../../..");
const expectedTree = "b68f9bb6b4ffb438935e12e684c7b1a989d1ad592afef166ad1ef1d1792ebe64";
const sourcePaths = [
  "src/editor/experimental-webcodecs.ts", "src/editor/audible-pcm.ts",
  "src/editor/silent-output-bootstrap.ts",
  "src/editor/audible-pcm-worklet.js", "tests/audible-proof-fixture.ts",
  "tests/audible-proof-fixture.html", "tests/audible-proof-browser.mjs",
  ...["export", "model", "media", "recording-clock", "overlay-renderer", "mp4-cadence"]
    .map(name => `src/editor/${name}.ts`),
];
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const sourceHashes = async () => Object.fromEntries(await Promise.all(sourcePaths.map(async path =>
  [path, hash(await readFile(join(root, path)))])));
async function packageTreeHash(base) {
  const files = [];
  async function walk(directory, prefix) {
    for (const item of await readdir(directory, {withFileTypes: true})) {
      const path = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.isDirectory()) await walk(join(directory, item.name), path);
      else {assert(item.isFile(), `Unexpected package entry ${path}`); files.push(path);}
    }
  }
  await walk(base, ""); files.sort();
  return hash((await Promise.all(files.map(async path =>
    `${path}\t${hash(await readFile(join(base, path)))}\n`))).join(""));
}
const receipt = {status: "running", partialSuite: true,
  scope: "Three-second audible original at 2×; no narration/music or full-product parity claim",
  runtimeProfile,
  artifacts, sourceHashesBefore: null, sourceHashesAfter: null,
  dependencyTreeBefore: null, dependencyTreeAfter: null,
  cases: [], checks: [], externalRequests: [], errors: []};
let browser, server, page;

const command = (binary, args, options = {}) => execFileSync(binary, args,
  {timeout: 30_000, maxBuffer: 32 * 1024 * 1024, ...options});
const probeJSON = (file, args) => JSON.parse(command("ffprobe",
  ["-v", "error", ...args, "-of", "json", file], {encoding: "utf8"}));
const pixel = (file, time, x = 100) => [...command("ffmpeg",
  ["-v", "error", "-ss", String(time), "-i", file, "-frames:v", "1",
    "-vf", `format=rgb24,crop=1:1:${x}:400`, "-f", "rawvideo", "pipe:1"])];
function pcmFloat(file) {
  const raw = command("ffmpeg", ["-v", "error", "-i", file, "-vn", "-ac", "1",
    "-ar", "48000", "-f", "f32le", "pipe:1"]);
  assert.equal(raw.byteLength % 4, 0);
  return new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4);
}
function windowPower(samples, start, end) {
  const first = Math.round(start * 48000), last = Math.round(end * 48000);
  assert(first >= 0 && last <= samples.length && last > first);
  let energy = 0;
  for (let i = first; i < last; i++) energy += samples[i] ** 2;
  return Math.sqrt(energy / (last - first));
}
function toneAmplitude(samples, frequency, start, end) {
  const first = Math.round(start * 48000), last = Math.round(end * 48000);
  assert(first >= 0 && last <= samples.length && last > first);
  let sine = 0, cosine = 0;
  for (let i = first; i < last; i++) {
    const phase = 2 * Math.PI * frequency * (i - first) / 48000;
    sine += samples[i] * Math.sin(phase);
    cosine += samples[i] * Math.cos(phase);
  }
  return 2 * Math.hypot(sine, cosine) / (last - first);
}
function dominantFrequency(samples, start, end) {
  let frequency = 0, amplitude = -Infinity;
  for (let candidate = 700; candidate <= 1000; candidate += 2) {
    const level = toneAmplitude(samples, candidate, start, end);
    if (level > amplitude) {frequency = candidate; amplitude = level;}
  }
  return {frequency, amplitude};
}
function zeroCrossingFrequency(samples, start, end) {
  const first = Math.round(start * 48000), last = Math.round(end * 48000);
  let crossings = 0;
  for (let i = first + 1; i < last; i++)
    if (samples[i - 1] < 0 && samples[i] >= 0) crossings++;
  return crossings / ((last - first) / 48000);
}
function verifyPCM(samples) {
  assert(windowPower(samples, .10, .40) < .01, "Opening photo gained source audio");
  assert(windowPower(samples, 2.65, 2.90) < .01, "Closing photo gained source audio");
  let onsetWindow = null;
  for (let at = .46; at <= .62; at += .005)
    if (windowPower(samples, at, at + .01) > .03) {
      onsetWindow = {start: at, end: at + .01}; break;
    }
  // This is a look-ahead RMS window; its END, not its start, must satisfy the
  // latest permissible source onset. Never infer a sample-accurate onset from
  // the beginning of a nonempty analysis window.
  assert(onsetWindow !== null && onsetWindow.start >= .48 &&
    onsetWindow.end <= .5 + 2 / 30,
    `Original sound started outside two-frame boundary: ${JSON.stringify(onsetWindow)}`);
  const marker = [];
  for (let at = .49; at <= .62; at += .005)
    marker.push({at, opening: toneAmplitude(samples, 990, at, at + .04),
      body: toneAmplitude(samples, 880, at, at + .04)});
  assert(marker.some(row => row.opening > .035 && row.opening > row.body * 1.5),
    "Distinct 990 Hz opening sound was lost after the photo boundary");
  const body = [.72, 1.2, 1.8, 2.30].map(at => ({at,
    original: toneAmplitude(samples, 880, at, at + .08),
    doubled: toneAmplitude(samples, 1760, at, at + .08),
    estimated: dominantFrequency(samples, at, at + .08),
    zeroCrossingsHz: zeroCrossingFrequency(samples, at, at + .08)}));
  assert(body.every(row => row.original > .04 && row.original > row.doubled * 2 &&
    Math.abs(row.estimated.frequency - 880) <= 30 &&
    Math.abs(row.zeroCrossingsHz - 880) <= 30),
    `2× playback changed original pitch: ${JSON.stringify(body)}`);
  let weakest40ms = Infinity;
  for (let at = .68; at + .04 <= 2.38; at += .04)
    weakest40ms = Math.min(weakest40ms, windowPower(samples, at, at + .04));
  assert(weakest40ms > .03, `Audible original has a silent 40 ms window: ${weakest40ms}`);
  return {onsetWindow, markerPeak: Math.max(...marker.map(row => row.opening)), body,
    weakest40ms, openingSilence: windowPower(samples, .10, .40),
    closingSilence: windowPower(samples, 2.65, 2.90)};
}
function verifyPixels(file) {
  const before = pixel(file, .4), after = pixel(file, 1.1);
  const dissolve = [.54, .58, .62, .66, .70, .74, .78, .82, .86]
    .map(time => ({time, rgb: pixel(file, time)}));
  const blends = dissolve.filter(({rgb}) => rgb[0] > 20 && rgb[0] < 100 &&
    rgb[2] > 170 && rgb[2] < 245);
  assert(blends.some((sample, index) => blends.slice(index + 1).some(later =>
    sample.rgb[0] - later.rgb[0] >= 8 && later.rgb[2] - sample.rgb[2] >= 8)),
  "Dissolve did not progress through decoded colors");
  assert(before[0] > 100 && before[0] < 135 && before[1] > 65 && before[1] < 95 &&
    before[2] > 135 && before[2] < 175, "Preceding shot must be purple");
  assert(after[0] < 10 && after[1] < 10 && after[2] > 240,
    "Following shot must be blue");
  const isWhip = ({left, right}) => left[2] > 200 && left[0] < 30 &&
    right[0] > 200 && right[2] < 30;
  const beforeWhip = {left: pixel(file, 2.4, 100), right: pixel(file, 2.4, 650)};
  const whip = [2.54, 2.58, 2.62, 2.66, 2.70, 2.74]
    .map(time => ({time, left: pixel(file, time, 100), right: pixel(file, time, 650)}));
  const afterWhip = {left: pixel(file, 2.9, 100), right: pixel(file, 2.9, 650)};
  assert(whip.some(isWhip), "Whip must split outgoing blue and incoming red");
  assert(beforeWhip.left[2] > 200 && beforeWhip.right[2] > 200 && !isWhip(beforeWhip),
    "Preceding shot must remain blue before the whip");
  assert(afterWhip.left[0] > 200 && afterWhip.right[0] > 200 && !isWhip(afterWhip),
    "Closing shot must be fully red after the whip");
  return {dissolve: {before, samples: dissolve, after}, beforeWhip, whip, afterWhip};
}

try {
  assert(entry && browserPath, "Pinned Mediabunny entry and Chrome path are required");
  assert(entry.endsWith("/node_modules/mediabunny/dist/modules/src/index.js"));
  receipt.sourceHashesBefore = await sourceHashes();
  receipt.dependencyTreeBefore = await packageTreeHash(packageRoot);
  assert.equal(receipt.dependencyTreeBefore, expectedTree, "Pinned Mediabunny tree changed");
  receipt.runtime = {node: process.version,
    ffmpeg: command("ffmpeg", ["-version"], {encoding: "utf8"}).split("\n")[0],
    ffprobe: command("ffprobe", ["-version"], {encoding: "utf8"}).split("\n")[0]};
  if (runtimeProfile === "hosted-exact") {
    assert.equal(receipt.runtime.node, "v24.22.2");
    assert(receipt.runtime.ffmpeg.startsWith("ffmpeg version 9.0.2 "));
    assert(receipt.runtime.ffprobe.startsWith("ffprobe version 9.0.2 "));
  }
  await build({configFile: false, root, publicDir: false, logLevel: "error",
    resolve: {alias: {mediabunny: entry}},
    build: {outDir: dist, rollupOptions: {input: join(root, "tests/audible-proof-fixture.html")}}});
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`) || request.method !== "GET")
      return response.writeHead(400).end();
    try {
      response.setHeader("Content-Type", ({".html": "text/html", ".js": "application/javascript"})[extname(path)] ?? "application/octet-stream");
      response.end(await readFile(path));
    } catch {response.writeHead(404).end();}
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const sourceVideo = join(artifacts, "audible-source.mp4");
  command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=4",
    "-f", "lavfi", "-i",
    "aevalsrc=if(lt(t\\,0.15)\\,0.25*sin(2*PI*990*t)\\,0.25*sin(2*PI*880*t)):s=48000:d=4",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", sourceVideo]);
  const sourceProbe = probeJSON(sourceVideo, ["-show_streams", "-show_format"]);
  assert(sourceProbe.streams.some(stream => stream.codec_name === "aac"),
    "Source must contain actual AAC original audio");
  browser = await chromium.launch({headless: true, executablePath: browserPath});
  receipt.runtime.browser = browser.version();
  if (runtimeProfile === "hosted-exact")
    assert.equal(receipt.runtime.browser, "153.0.8010.12");
  const context = await browser.newContext({viewport: {width: 1440, height: 1100},
    serviceWorkers: "block", acceptDownloads: true});
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if ((url.origin === origin && route.request().method() === "GET") ||
        url.protocol === "blob:") return route.continue();
    receipt.externalRequests.push(url.href); return route.abort();
  });
  const sourceBytes = await readFile(sourceVideo);
  const fresh = async () => {
    await page?.close();
    page = await context.newPage();
    page.setDefaultTimeout(15_000);
    page.on("pageerror", error => receipt.errors.push(error.message));
    await page.goto(`${origin}/tests/audible-proof-fixture.html`);
    const colored = async color => Buffer.from((await page.evaluate(color => {
      const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 450;
      const ctx = canvas.getContext("2d"); ctx.fillStyle = color;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      return canvas.toDataURL("image/png").split(",")[1];
    }, color)), "base64");
    await page.locator("#opening").setInputFiles({name: "opening.png", mimeType: "image/png",
      buffer: await colored("#77509c")});
    await page.locator("#source").setInputFiles({name: "source.mp4", mimeType: "video/mp4",
      buffer: sourceBytes});
    await page.locator("#closing").setInputFiles({name: "closing.png", mimeType: "image/png",
      buffer: await colored("#f00")});
    await page.getByRole("button", {name: "Prepare local files"}).click();
    await expect.poll(() => page.evaluate(() => window.audibleProofFixture?.prepared))
      .toBe(true);
    assert.equal(await page.evaluate(() => window.audibleProofFixture?.controller), null);
  };
  let downloads = 0;
  await fresh();
  page.on("download", () => {downloads++;});
  await page.getByRole("button", {name: "Export audible proof"}).click();
  await expect.poll(() => page.evaluate(() => window.audibleProofFixture?.result),
    {timeout: 90_000}).not.toBeNull();
  const result = await page.evaluate(() => window.audibleProofFixture.result);
  const webCodecs = await page.evaluate(() => window.webCodecsAudibleProof ?? null);
  const pcmTrace = await page.evaluate(() => window.audiblePCMProof ?? null);
  const bootstrap = await page.evaluate(() => window.audibleSilentStreamBootstrap ?? null);
  receipt.cases.push({name: "audible-original", result, webCodecs, pcmTrace, bootstrap});
  assert.equal(result.ok, true, result.error);
  assert.equal(downloads, 0, "Proof may not auto-download");
  assert.equal(webCodecs.kind, "webcodecs-audible-original-proof");
  assert.equal(webCodecs.audio.frames, 144000);
  assert.equal(webCodecs.audio.blocks, 141);
  assert.equal(webCodecs.audio.channels, 2);
  assert.equal(webCodecs.audio.sampleRate, 48000);
  assert(webCodecs.audio.maxQueueDepth <= 8);
  assert.equal(pcmTrace.phase, "closed");
  assert.equal(pcmTrace.audioStateAfterClose, "closed");
  assert.equal(pcmTrace.ownedTracksAfterClose, 0);
  assert.equal(bootstrap?.kind, "early-silent-stream-bootstrap");
  assert.equal(bootstrap.connectedToStreamSink, true);
  assert.equal(bootstrap.started, true);
  assert.equal(bootstrap.liveTracksAfterStop, 0);
  assert.equal(bootstrap.disconnected, true);
  assert(bootstrap.startedWallMs <= pcmTrace.startupClock.startedWallMs,
    "The silent stream sink must start before startup admission");
  assert.equal(webCodecs.requested, 90);
  assert.equal(webCodecs.encoded.length, 90);
  assert.equal(webCodecs.finalized, true);
  assert.equal(webCodecs.failed, false);
  const orderedPackets = webCodecs.encoded.map(row => row.timestamp).sort((a, b) => a - b);
  for (let i = 0; i < 90; i++)
    assert(Math.abs(orderedPackets[i] - i / 30) <= .001,
      `Encoded frame ${i} presentation timestamp changed`);
  const pendingDownload = page.waitForEvent("download");
  await page.locator("#download").click();
  const file = join(artifacts, "audible-proof.mp4");
  await (await pendingDownload).saveAs(file);
  assert.equal(downloads, 1);
  const probe = probeJSON(file, ["-show_streams", "-show_format"]);
  const videoStreams = probe.streams.filter(stream => stream.codec_type === "video");
  const audioStreams = probe.streams.filter(stream => stream.codec_type === "audio");
  assert.equal(videoStreams.length, 1, "Proof requires exactly one video track");
  assert.equal(audioStreams.length, 1, "Proof requires exactly one audio track");
  assert.equal(videoStreams[0].codec_name, "h264");
  assert.equal(audioStreams[0].codec_name, "aac");
  assert.equal(Number(audioStreams[0].sample_rate), 48000);
  assert.equal(Number(audioStreams[0].channels), 2);
  const avDurationGap = Math.abs(Number(audioStreams[0].duration) -
    Number(videoStreams[0].duration));
  assert(Number.isFinite(avDurationGap) && avDurationGap <= 2 / 30,
    `Audio/video stream durations disagree: ${avDurationGap}`);
  assert(Math.abs(Number(probe.format.duration) - 3) <= 2 / 30,
    `MP4 duration departed from the exact 3 s edit: ${probe.format.duration}`);
  const frames = probeJSON(file, ["-select_streams", "v:0", "-show_frames",
    "-show_entries", "frame=best_effort_timestamp_time"]).frames;
  assert.equal(frames.length, 90);
  const pts = frames.map(frame => Number(frame.best_effort_timestamp_time)).sort((a, b) => a - b);
  for (let i = 0; i < 90; i++)
    assert(Math.abs(pts[i] - i / 30) <= .001,
      `Decoded frame ${i} presentation timestamp changed`);
  const samples = pcmFloat(file);
  receipt.cases[0].probes = {duration: Number(probe.format.duration), avDurationGap,
    decodedFrames: frames.length, pcm: verifyPCM(samples), pixels: verifyPixels(file)};
  receipt.checks.push("Audible 990 Hz first sound and pitch-preserved 880 Hz body survived 2× playback");
  receipt.checks.push("Exactly 144000 PCM frames/141 blocks, 90 encoded/decoded video frames, AAC and transitions");
  // Native playback can start before its play() promise settles. A late
  // promise alone must keep the actual audio and its opening sound intact.
  await fresh();
  await page.evaluate(() => {window.audibleProofFixture.fault = "delay-play-promise-only";});
  let positiveDownloads = 0;
  page.on("download", () => {positiveDownloads++;});
  await page.getByRole("button", {name: "Export audible proof"}).click();
  await expect.poll(() => page.evaluate(() => window.audibleProofFixture?.result),
    {timeout: 90_000}).not.toBeNull();
  const delayed = await page.evaluate(() => ({result: window.audibleProofFixture.result,
    injected: window.audibleProofFixture.injected,
    pcm: window.audiblePCMProof, webCodecs: window.webCodecsAudibleProof,
    bootstrap: window.audibleSilentStreamBootstrap ?? null,
    outerAudioState: window.audibleProofOuterAudioState}));
  receipt.cases.push({name: "late-promise-with-native-playback", ...delayed});
  assert.equal(delayed.injected, true);
  assert.equal(delayed.result.ok, true, delayed.result.error);
  assert.equal(delayed.pcm.phase, "closed");
  assert.equal(delayed.outerAudioState, "closed");
  assert.equal(delayed.bootstrap?.liveTracksAfterStop, 0);
  assert.equal(positiveDownloads, 0);
  const secondDownload = page.waitForEvent("download");
  await page.locator("#download").click();
  const delayedFile = join(artifacts, "audible-delayed-promise.mp4");
  await (await secondDownload).saveAs(delayedFile);
  assert.equal(positiveDownloads, 1);
  receipt.cases.at(-1).pcmProbe = verifyPCM(pcmFloat(delayedFile));
  receipt.checks.push("Delayed play-promise delivery preserves actual native playback and opening PCM");

  // Every refused path must keep the output link and download count at zero.
  const refusedCases = [
    {fault: "drop-first-block", error: /Worklet PCM/},
    {fault: "withhold-credits", error: /Worklet PCM/},
    {fault: "delay-native-play", error: /Proof source|Original audio|Audio and picture/},
    {fault: "stall-original-100ms", error: /Proof source|Original audio|Audio and picture/},
    {fault: "cancel-before-capture", error: /Synthetic pre-capture cancellation/},
    {fault: "cancel-during-capture", error: /Synthetic capture cancellation/},
    {fault: "revision-during-capture", error: /edit changed|cancelled/i},
    {fault: "suspend-during-capture", error: /Audio stopped|Audio clock|Audio and picture/},
  ];
  for (const {fault, error} of refusedCases) {
    await fresh();
    await page.evaluate(fault => {window.audibleProofFixture.fault = fault;}, fault);
    let faultDownloads = 0;
    page.on("download", () => {faultDownloads++;});
    await page.getByRole("button", {name: "Export audible proof"}).click();
    await expect.poll(() => page.evaluate(() => window.audibleProofFixture?.result),
      {timeout: 90_000}).not.toBeNull();
    const refused = await page.evaluate(() => ({result: window.audibleProofFixture.result,
      injected: window.audibleProofFixture.injected,
      pcm: window.audiblePCMProof ?? null,
      webCodecs: window.webCodecsAudibleProof ?? null,
      bootstrap: window.audibleSilentStreamBootstrap ?? null,
      outerAudioState: window.audibleProofOuterAudioState ?? null}));
    receipt.cases.push({name: fault, ...refused});
    assert.equal(refused.result.ok, false, `${fault} must refuse`);
    assert.match(refused.result.error, error);
    if (fault !== "drop-first-block" && fault !== "withhold-credits")
      assert.equal(refused.injected, true, `${fault} must exercise its injection`);
    assert.equal(await page.locator("a[download][href]").count(), 0);
    assert.equal(faultDownloads, 0);
    assert.equal(refused.outerAudioState, "closed");
    assert.equal(refused.bootstrap?.liveTracksAfterStop, 0);
    if (refused.pcm) {
      assert.equal(refused.pcm.audioStateAfterClose, "closed");
      assert.equal(refused.pcm.ownedTracksAfterClose, 0);
    }
  }
  assert.deepEqual(receipt.externalRequests, []);
  assert.deepEqual(receipt.errors, []);
  receipt.status = "prototype-case-passed";
} catch (error) {
  receipt.status = "failed";
  receipt.failure = error instanceof Error ? `${error.stack ?? error.message}` : String(error);
  process.exitCode = 1;
} finally {
  if (page && !page.isClosed()) {
    receipt.lastPage = await page.evaluate(() => ({result: window.audibleProofFixture?.result ?? null,
      pcm: window.audiblePCMProof ?? null, webCodecs: window.webCodecsAudibleProof ?? null,
      bootstrap: window.audibleSilentStreamBootstrap ?? null,
      setupClose: window.audibleProofSetupClose ?? null}))
      .catch(() => null);
    await page.screenshot({path: join(artifacts, "last-page.png"), fullPage: true}).catch(() => undefined);
  }
  await browser?.close().catch(() => undefined);
  await new Promise(resolve => server?.close(resolve) ?? resolve());
  try {
    receipt.sourceHashesAfter = await sourceHashes();
    receipt.dependencyTreeAfter = await packageTreeHash(packageRoot);
    if (JSON.stringify(receipt.sourceHashesAfter) !== JSON.stringify(receipt.sourceHashesBefore) ||
        receipt.dependencyTreeAfter !== expectedTree) {
      receipt.status = "failed";
      receipt.failure = `${receipt.failure ?? ""}\nSource or dependency changed during proof.`;
      process.exitCode = 1;
    }
  } catch (error) {
    receipt.status = "failed";
    receipt.failure = `${receipt.failure ?? ""}\nPostrun source binding failed: ${String(error)}`;
    process.exitCode = 1;
  }
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify({status: receipt.status, partialSuite: true, artifacts}));
}
