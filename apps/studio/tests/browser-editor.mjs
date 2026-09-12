#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { chromium, expect } from "@playwright/test";

// Production-byte verification only. This script never rebuilds dist, contacts
// providers, or uses a saved browser profile. Coordinate one build before suites.
const args = process.argv.slice(2);
let baseArgument;
let startPreview = false;
let deployedPreview = false;
for (let index = 0; index < args.length; index++) {
  const argument = args[index];
  if (argument === "--start-preview") startPreview = true;
  else if (argument === "--deployed-preview") deployedPreview = true;
  else if (argument === "--base-url") {
    baseArgument = args[++index];
    assert.ok(baseArgument, "--base-url requires a URL.");
  } else if (argument.startsWith("--base-url="))
    baseArgument = argument.slice("--base-url=".length);
  else
    throw new Error(
      `Unknown argument: ${argument}. Use --base-url=http://127.0.0.1:4179 and optionally --start-preview, or --deployed-preview --base-url=https://studio.rendprop.com.`,
    );
}
const base = new URL(
  baseArgument ?? process.env.STUDIO_BASE_URL ?? "http://127.0.0.1:4179",
);
assert.ok(
  deployedPreview
    ? base.origin === "https://studio.rendprop.com"
    : base.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(base.hostname),
  "Editor checks default to local HTTP only; --deployed-preview permits only https://studio.rendprop.com.",
);
assert.ok(
  !(deployedPreview && startPreview),
  "--deployed-preview cannot be combined with --start-preview.",
);
assert.equal(base.pathname, "/", "Use the preview origin, without a pathname.");
assert.ok(
  !base.username && !base.password && !base.search && !base.hash,
  "Preview URL must not contain credentials, a query, or a fragment.",
);

const appDirectory = fileURLToPath(new URL("../", import.meta.url));
const distDirectory = join(appDirectory, "dist");
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-editor-browser-"));
const receipt = {
  target: base.origin,
  deployedPreview,
  requestPolicy: "Fresh isolated context; same-origin GET/HEAD only; redirects and WebSockets blocked.",
  startedAt: new Date().toISOString(),
  artifacts,
  status: "running",
  checks: [],
  skipped: 0,
  exports: [],
  servedAssets: [],
  assetErrors: [],
  externalRequests: [],
  disallowedRequests: [],
  consoleErrors: [],
  limits: { durationToleranceSeconds: 0.35, requestedTrimSeconds: 2 },
  visibilityProof:
    "Headless platform-event simulation: document.hidden=true during a dispatched visibilitychange. Real OS tab visibility is not claimed.",
  mediaIdentityProof:
    "Same-name, same-size changed-file rejection is covered by browser-workspace.mjs; not duplicated here.",
};
let browser;
let previewProcess;
let activePage;
let previewOutput = "";
let beforeDist;
const responseChecks = [];
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const check = (name, details = {}) => receipt.checks.push({ name, ...details });

async function fingerprintDist() {
  const files = [];
  async function visit(directory) {
    for (const entry of (
      await readdir(directory, { withFileTypes: true })
    ).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) {
        const bytes = await readFile(path);
        files.push({
          path: relative(distDirectory, path).replaceAll("\\", "/"),
          bytes: bytes.byteLength,
          sha256: sha256(bytes),
        });
      }
    }
  }
  await visit(distDirectory);
  assert.ok(
    files.some((file) => file.path === "index.html"),
    "Build Studio before running browser-editor.mjs.",
  );
  return { sha256: sha256(JSON.stringify(files)), files };
}

async function command(
  program,
  commandArgs,
  { maximumBytes = 4 * 1024 * 1024, timeoutMs = 30_000 } = {},
) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, commandArgs, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout = [],
      stderr = [];
    let bytes = 0;
    let failure;
    const timeout = setTimeout(() => {
      failure = new Error(`${program} exceeded ${timeoutMs} ms.`);
      child.kill("SIGKILL");
    }, timeoutMs);
    const collect = (destination) => (data) => {
      bytes += data.length;
      if (bytes > maximumBytes) {
        failure = new Error(
          `${program} output exceeded its test-only ${maximumBytes}-byte cap.`,
        );
        child.kill("SIGKILL");
        return;
      }
      destination.push(data);
    };
    child.stdout.on("data", collect(stdout));
    child.stderr.on("data", collect(stderr));
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("exit", (code) => {
      clearTimeout(timeout);
      const errorOutput = Buffer.concat(stderr).toString("utf8");
      if (failure || code !== 0)
        reject(
          failure ?? new Error(`${program} exited ${code}: ${errorOutput}`),
        );
      else resolve({ stdout: Buffer.concat(stdout), stderr: errorOutput });
    });
  });
}

async function waitForPreview() {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (previewProcess && previewProcess.exitCode !== null)
      throw new Error(`Preview exited: ${previewOutput}`);
    try {
      const response = await fetch(base, { method: "GET", redirect: "error", signal: AbortSignal.timeout(1000) });
      if (response.ok) return;
    } catch {
      /* Startup may not yet be listening. The overall deadline still fails. */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Built preview was not available within 15 seconds at ${base.origin}.`,
  );
}

async function mediaProbe(path) {
  const result = await command("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "stream=codec_name,codec_type,width,height,duration,channels,sample_rate:format=duration,size,format_name",
    "-of",
    "json",
    path,
  ]);
  return JSON.parse(result.stdout.toString("utf8"));
}

async function measuredDuration(path, probe) {
  const metadataDuration = Number(probe.format.duration);
  if (Number.isFinite(metadataDuration))
    return { seconds: metadataDuration, measuredFrom: "container metadata" };
  // MediaRecorder WebM can omit the duration header. Read the actual packet
  // timeline rather than treating a missing header as zero or skipping timing.
  const result = await command("ffprobe", [
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "packet=pts_time,duration_time",
    "-of",
    "json",
    path,
  ]);
  const packets = JSON.parse(result.stdout.toString("utf8")).packets;
  assert.ok(
    Array.isArray(packets) && packets.length > 1,
    "A duration-less container must still have measurable video packets.",
  );
  const pts = packets.map((packet) => Number(packet.pts_time));
  assert.ok(
    pts.every(Number.isFinite),
    "Video packet timestamps must be finite.",
  );
  const last = packets.at(-1);
  const lastDuration = Number(last.duration_time);
  const duration =
    pts.at(-1) +
    (Number.isFinite(lastDuration) && lastDuration > 0
      ? lastDuration
      : pts.at(-1) - pts.at(-2)) -
    pts[0];
  assert.ok(
    Number.isFinite(duration) && duration > 0,
    "Measured packet duration must be positive.",
  );
  return {
    seconds: duration,
    measuredFrom:
      "decoded video packet timestamps (container omits duration header)",
  };
}

async function assertTone(path, startSeconds = 0.35) {
  // Ignore browser startup padding; analyze decoded samples from the middle of
  // the trimmed source. This rejects both an empty audio track and silence.
  const result = await command("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    path,
    "-ss",
    String(startSeconds),
    "-t",
    "1.1",
    "-vn",
    "-ac",
    "1",
    "-ar",
    "48000",
    "-f",
    "s16le",
    "pipe:1",
  ]);
  const samples = result.stdout.length / 2;
  assert.ok(
    samples > 40_000,
    `Expected actual decoded audio samples, got ${samples}.`,
  );
  let sumSquares = 0;
  let crossings = 0;
  let previous = 0;
  for (let offset = 0; offset < result.stdout.length; offset += 2) {
    const value = result.stdout.readInt16LE(offset) / 32768;
    sumSquares += value * value;
    if (previous < 0 && value >= 0) crossings++;
    previous = value;
  }
  const rms = Math.sqrt(sumSquares / samples);
  const frequencyHz = crossings / (samples / 48_000);
  assert.ok(
    rms > 0.01 && rms < 0.3,
    `Expected the fixture tone's nonzero amplitude, got RMS ${rms}.`,
  );
  assert.ok(
    frequencyHz >= 430 && frequencyHz <= 450,
    `Expected the original 440 Hz tone, got ${frequencyHz} Hz.`,
  );
  return { samples, rms, frequencyHz };
}

async function lightPixels(path, yFraction = 0.76, heightFraction = 0.17) {
  const filter = `crop=iw*0.85:ih*${heightFraction}:iw*0.075:ih*${yFraction}`;
  const result = await command("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    path,
    "-ss",
    "1",
    "-frames:v",
    "1",
    "-vf",
    filter,
    "-pix_fmt",
    "rgb24",
    "-f",
    "rawvideo",
    "pipe:1",
  ]);
  let count = 0;
  for (let offset = 0; offset + 2 < result.stdout.length; offset += 3) {
    const [r, g, b] = result.stdout.subarray(offset, offset + 3);
    if (Math.min(r, g, b) > 210 && Math.max(r, g, b) - Math.min(r, g, b) < 30)
      count++;
  }
  return count;
}

async function downloadExport(
  page,
  format,
  name,
  { audio, ratio, seconds, caption = false, toneStart = 0.35 },
) {
  await page
    .getByRole("combobox", { name: /^Export format/ })
    .selectOption(format.value);
  await page.locator(".rp-editor-export-button").click();
  const link = page.locator(".rp-editor-download");
  await expect(link).toBeVisible({ timeout: 30_000 });
  await expect(
    page.getByRole("button", { name: "Cancel export", exact: true }),
  ).toHaveCount(0);
  const completion = page.getByRole("status").filter({ hasText: /^Your local (MP4|WEBM) is ready to download\./ });
  await expect(completion).toHaveCount(1);
  await expect(page.getByRole("region", { name: "Local video editor" }).getByRole("status").filter({ hasText: /^Your local (MP4|WEBM) is ready to download\./ })).toHaveCount(1);
  const pending = page.waitForEvent("download");
  await link.click();
  const download = await pending;
  const extension = format.value.startsWith("video/mp4") ? "mp4" : "webm";
  assert.ok(
    download.suggestedFilename().endsWith(`.${extension}`),
    "Download extension must match the selected container.",
  );
  const path = join(artifacts, `${name}.${extension}`);
  await download.saveAs(path);
  assert.equal(
    await download.failure(),
    null,
    "Browser download must complete.",
  );
  const probe = await mediaProbe(path);
  const video = probe.streams.find((stream) => stream.codec_type === "video");
  const audioStreams = probe.streams.filter(
    (stream) => stream.codec_type === "audio",
  );
  assert.ok(video, "Downloaded output needs a real video stream.");
  assert.deepEqual(
    [video.width, video.height],
    ratio,
    "Export must use the selected aspect ratio and output size.",
  );
  const timing = await measuredDuration(path, probe);
  assert.ok(
    Math.abs(timing.seconds - seconds) <=
      receipt.limits.durationToleranceSeconds,
    `Expected ${seconds}s ±${receipt.limits.durationToleranceSeconds}s, got ${timing.seconds}s.`,
  );
  assert.ok(
    Number(probe.format.size) > 1000,
    "Export must contain actual encoded bytes.",
  );
  if (extension === "mp4") {
    assert.match(probe.format.format_name, /mp4/);
    assert.equal(
      video.codec_name,
      "h264",
      "Advertised H.264 MP4 must actually contain H.264.",
    );
  } else {
    assert.match(probe.format.format_name, /webm/);
    assert.ok(
      ["vp8", "vp9", "av1"].includes(video.codec_name),
      "WebM must contain a valid advertised-family video codec.",
    );
    if (format.value.includes("vp8")) assert.equal(video.codec_name, "vp8");
  }
  let audioEvidence;
  if (audio) {
    assert.equal(
      audioStreams.length,
      1,
      "Original audio export must contain exactly one audio track.",
    );
    assert.ok(
      audioStreams[0].channels >= 1,
      "Original audio must contain channels.",
    );
    assert.equal(
      audioStreams[0].codec_name,
      extension === "mp4" ? "aac" : "opus",
    );
    audioEvidence = await assertTone(path, toneStart);
  } else
    assert.equal(
      audioStreams.length,
      0,
      "Photo-only or explicitly muted export must not include an audio track.",
    );
  let captionLightPixels;
  if (caption) {
    captionLightPixels = await lightPixels(path);
    assert.ok(
      captionLightPixels > 500,
      `Caption should produce white text in the known dark source region, got ${captionLightPixels} light pixels.`,
    );
  }
  const framePath = join(artifacts, `${name}-frame.png`);
  await command("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    path,
    "-ss",
    "1",
    "-frames:v",
    "1",
    framePath,
  ]);
  const evidence = {
    name,
    format,
    path,
    suggestedFilename: download.suggestedFilename(),
    sha256: sha256(await readFile(path)),
    probe,
    timing,
    audioEvidence,
    captionLightPixels,
    completionAnnouncements: await completion.count(),
    framePath,
  };
  receipt.exports.push(evidence);
  return evidence;
}

async function assertPhotoThenVideo(path) {
  const centerPixel = async (seconds) => {
    const result = await command("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", path, "-ss", String(seconds), "-frames:v", "1", "-vf", "crop=2:2:iw/2:ih/2", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]);
    assert.ok(result.stdout.length >= 3, "The ordered export must have a decoded frame at each sampled time.");
    return [...result.stdout.subarray(0, 3)];
  };
  const firstRGB = await centerPixel(0.3);
  const secondRGB = await centerPixel(1.6);
  const photoRGB = [52, 38, 79];
  assert.ok(firstRGB.every((value, index) => Math.abs(value - photoRGB[index]) <= 15), `Expected the purple photo first, got RGB ${firstRGB}.`);
  assert.ok(secondRGB.some((value, index) => Math.abs(value - photoRGB[index]) > 30), `Expected the video after the photo, got RGB ${secondRGB}.`);
  const silence = await command("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", path, "-vn", "-af", "aresample=async=1:first_pts=0,atrim=start=0.2:end=0.7", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
  assert.ok(silence.stdout.length >= 40_000, "The photo interval must have a measurable audio timeline.");
  let sumSquares = 0;
  for (let index = 0; index < silence.stdout.length; index += 2) sumSquares += (silence.stdout.readInt16LE(index) / 32768) ** 2;
  const silentRMS = Math.sqrt(sumSquares / (silence.stdout.length / 2));
  assert.ok(silentRMS < 0.001, `Audio must be silent during the photo, got RMS ${silentRMS}.`);
  return { firstRGB, secondRGB, silentRMS };
}

async function beginLongExport(page, format) {
  await page
    .getByRole("combobox", { name: /^Export format/ })
    .selectOption(format.value);
  await page.locator(".rp-editor-export-button").click();
  await expect(
    page.getByRole("button", { name: "Cancel export", exact: true }),
  ).toBeVisible();
  await expect
    .poll(
      () =>
        page
          .getByRole("progressbar", { name: "Local video export progress" })
          .evaluate((element) => element.value),
      { timeout: 15_000 },
    )
    .toBeGreaterThan(0);
}

try {
  beforeDist = await fingerprintDist();
  receipt.dist = beforeDist;
  const versions = await Promise.all([
    command("ffmpeg", ["-version"]),
    command("ffprobe", ["-version"]),
  ]);
  receipt.ffmpeg = versions[0].stdout.toString("utf8").split("\n")[0];
  receipt.ffprobe = versions[1].stdout.toString("utf8").split("\n")[0];
  if (startPreview) {
    let occupied = false;
    try {
      await fetch(base, { method: "GET", redirect: "error", signal: AbortSignal.timeout(1000) });
      occupied = true;
    } catch {
      /* The owned preview must use an unused local port. */
    }
    assert.equal(
      occupied,
      false,
      "Preview port is occupied; omit --start-preview to use the existing server.",
    );
    previewProcess = spawn(
      process.execPath,
      [
        join(appDirectory, "node_modules/vite/bin/vite.js"),
        "preview",
        "--host",
        base.hostname,
        "--port",
        base.port || "4179",
        "--strictPort",
      ],
      { cwd: appDirectory, stdio: ["ignore", "pipe", "pipe"] },
    );
    const collect = (data) => {
      previewOutput = (previewOutput + data.toString()).slice(-12_000);
    };
    previewProcess.stdout.on("data", collect);
    previewProcess.stderr.on("data", collect);
  }
  await waitForPreview();
  const html = await (await fetch(base, { method: "GET", redirect: "error", signal: AbortSignal.timeout(15_000) })).arrayBuffer();
  assert.equal(
    sha256(Buffer.from(html)),
    beforeDist.files.find((file) => file.path === "index.html").sha256,
    "Preview HTML must match the built index.html bytes.",
  );
  const source = join(artifacts, "source-tone.mp4");
  const photo = join(artifacts, "source-photo.png");
  await command("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    // The portrait crop must visibly change on every frame, otherwise a WebM
    // encoder can represent a static tail by holding its last video packet.
    "nullsrc=size=640x360:rate=30,geq=r='if(lt(Y,240),120+40*sin(N*0.5),36)':g='if(lt(Y,240),30+15*cos(N*0.5),50)':b='if(lt(Y,240),45+10*sin(N*0.2),72)'",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440:sample_rate=48000",
    "-t",
    "3",
    "-c:v",
    "libx264",
    "-pix_fmt",
    "yuv420p",
    "-c:a",
    "aac",
    "-shortest",
    source,
  ]);
  await command("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "color=c=0x34264f:s=640x360",
    "-frames:v",
    "1",
    photo,
  ]);
  assert.ok(
    (await lightPixels(source)) < 20,
    "Caption proof fixture must contain no white text in the tested region before export.",
  );
  check(
    "bounded synthetic video, 440 Hz original audio, and photo generated in an owned temporary directory",
  );

  browser = await chromium.launch({
    headless: true,
    ...(process.env.STUDIO_BROWSER_EXECUTABLE
      ? { executablePath: process.env.STUDIO_BROWSER_EXECUTABLE }
      : {}),
  });
  receipt.browserVersion = browser.version();
  const context = await browser.newContext({
    acceptDownloads: true,
    viewport: { width: 1440, height: 1000 },
    serviceWorkers: "block",
  });
  await context.routeWebSocket("**/*", (socket) => {
    const url = new URL(socket.url());
    receipt.disallowedRequests.push(`WebSocket ${url.origin}${url.pathname}`);
    socket.close();
  });
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.origin !== base.origin) {
      receipt.externalRequests.push(`${url.origin}${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    if (!["GET", "HEAD"].includes(request.method())) {
      receipt.disallowedRequests.push(`${request.method()} ${url.origin}${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    try {
      // Do not follow a same-origin response to a cross-origin redirect before
      // the browser's routing hook gets another chance to inspect it.
      const response = await route.fetch({ maxRedirects: 0, timeout: 15_000 });
      if (response.status() >= 300 && response.status() < 400) {
        receipt.disallowedRequests.push(`Redirect ${url.origin}${url.pathname}`);
        return route.abort("blockedbyclient");
      }
      await route.fulfill({ response });
    } catch (error) {
      receipt.assetErrors.push(`Read-only request failed: ${error.message}`);
      await route.abort("failed").catch(() => {});
    }
  });
  const page = await context.newPage();
  activePage = page;
  page.on("pageerror", (error) => receipt.consoleErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") receipt.consoleErrors.push(message.text());
  });
  page.on("response", (response) => {
    const url = new URL(response.url());
    if (
      url.origin !== base.origin ||
      !(url.pathname === "/" || url.pathname.startsWith("/assets/")) ||
      response.status() !== 200
    )
      return;
    const promise = response
      .body()
      .then((bytes) => {
        const path = url.pathname === "/" ? "index.html" : decodeURIComponent(url.pathname.slice(1));
        const expected = beforeDist.files.find((file) => file.path === path);
        const actualHash = sha256(bytes);
        assert.ok(
          expected,
          `Served asset ${path} is absent from the fingerprinted dist.`,
        );
        assert.equal(
          actualHash,
          expected.sha256,
          `Served asset ${path} differs from the built bytes.`,
        );
        receipt.servedAssets.push({
          path,
          sha256: actualHash,
          bytes: bytes.length,
        });
      })
      .catch((error) => receipt.assetErrors.push(error.message));
    responseChecks.push(promise);
  });
  await page.goto(base.href, { waitUntil: "networkidle" });
  assert.equal(
    await page.locator('script[src*="@vite/client"]').count(),
    0,
    "This test must use built dist, not the Vite dev server.",
  );
  await page
    .getByRole("navigation", { name: "Studio navigation" })
    .getByRole("button", { name: /^Video editor(?: NEW)?$/ })
    .click();
  await expect(
    page.getByRole("heading", { name: "Video editor", exact: true, level: 1 }),
  ).toBeVisible();
  const editor = page.getByRole("region", { name: "Local video editor" });
  const undo = editor.getByRole("button", { name: "Undo", exact: true });
  const redo = editor.getByRole("button", { name: "Redo", exact: true });
  const revision = async () => Number((await editor.locator(".rp-editor-revision").innerText()).replace("Rev ", ""));
  await expect(undo).toBeDisabled();
  await expect(redo).toBeDisabled();
  await expect(editor.getByRole("heading", { name: "Bring your story to life.", exact: true })).toBeVisible();
  await page
    .getByLabel("Add photos or videos", { exact: true })
    .setInputFiles(source);
  await expect(
    page.getByRole("button", { name: /^Select clip 1: source-tone.mp4/ }),
  ).toBeVisible();
  await expect(
    page.getByLabel("Trim start (sec)", { exact: true }),
  ).toBeEnabled();
  await page.getByRole("button", { name: "Play", exact: true }).click();
  await expect(page.getByRole("button", { name: "Pause", exact: true })).toBeVisible();
  await page.getByRole("navigation", { name: "Studio navigation" }).getByRole("button", { name: "Content planner", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Content planner", level: 1, exact: true })).toBeVisible();
  await expect(editor).toBeHidden();
  await page.getByRole("navigation", { name: "Studio navigation" }).getByRole("button", { name: /^Video editor(?: NEW)?$/ }).click();
  await expect(editor).toBeVisible();
  await expect(page.getByRole("button", { name: "Reselect original file", exact: true })).toHaveCount(0);
  await expect(page.locator(".rp-editor-export-button")).toBeEnabled();
  await expect(page.getByRole("button", { name: /^(Play|Replay)$/, exact: true })).toBeEnabled();
  check("navigation to planner pauses playback and preserves verified local media when returning to editor");
  await page.getByLabel("Trim start (sec)", { exact: true }).fill("0.5");
  await page.getByLabel("Trim end (sec)", { exact: true }).fill("2.5");
  await page
    .getByLabel("Clip caption", { exact: false })
    .fill("ORIGINAL AUDIO RETAINED");
  await page.getByRole("combobox", { name: /^Audio/ }).selectOption("original");
  const beforeHistory = await revision();
  await undo.click();
  await expect(page.getByLabel("Clip caption", { exact: false })).toHaveValue("");
  await undo.click();
  await expect(page.getByLabel("Trim end (sec)", { exact: true })).toHaveValue("3");
  await undo.click();
  await expect(page.getByLabel("Trim start (sec)", { exact: true })).toHaveValue("0");
  await redo.click();
  await redo.click();
  await redo.click();
  await expect(page.getByLabel("Trim start (sec)", { exact: true })).toHaveValue("0.5");
  await expect(page.getByLabel("Trim end (sec)", { exact: true })).toHaveValue("2.5");
  await expect(page.getByLabel("Clip caption", { exact: false })).toHaveValue("ORIGINAL AUDIO RETAINED");
  assert.equal(await revision(), beforeHistory + 6, "Undo/Redo must allocate new revisions, never restore stale export identities.");
  await expect(page.locator(".rp-editor-export-button")).toBeEnabled();
  check("Undo/Redo restores exact trims and caption with monotonic revisions and keeps current original media connected");
  const formats = await page
    .getByRole("combobox", { name: /^Export format/ })
    .locator("option")
    .evaluateAll((options) =>
      options.map((option) => ({
        value: option.value,
        label: option.textContent,
      })),
    );
  assert.ok(
    formats.length > 0,
    "This Chromium runtime must offer a real local export format. No media checks may be skipped.",
  );
  receipt.advertisedFormats = formats;
  const primary =
    formats.find((format) => format.value.startsWith("video/mp4")) ??
    formats[0];
  receipt.primaryFormat = primary;
  for (const [index, format] of [
    primary,
    ...formats.filter((format) => format !== primary),
  ].entries()) {
    await downloadExport(page, format, `original-audio-${index + 1}`, {
      audio: true,
      ratio: [720, 1280],
      seconds: 2,
      caption: true,
    });
  }
  await page.screenshot({
    path: join(artifacts, "video-export-complete.png"),
    fullPage: true,
  });
  check(
    "every offered video format exports real trimmed 9:16 video, matching codecs, decoded 440 Hz audio, burned caption pixels, and exactly one editor-owned completion announcement",
    { count: formats.length },
  );

  await page.getByRole("combobox", { name: /^Aspect ratio/ }).selectOption("1:1");
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  await expect(page.getByRole("status").filter({ hasText: /^Your local (MP4|WEBM) is ready to download\./ })).toHaveCount(0);
  await undo.click();
  await expect(page.getByRole("combobox", { name: /^Aspect ratio/ })).toHaveValue("9:16");
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  await redo.click();
  await expect(page.getByRole("combobox", { name: /^Aspect ratio/ })).toHaveValue("1:1");
  await undo.click();
  await expect(page.getByRole("combobox", { name: /^Aspect ratio/ })).toHaveValue("9:16");
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  check("ratio Undo/Redo restores settings without reviving a completed export or stale ready announcement");

  await page
    .getByLabel("Title overlay", { exact: true })
    .fill("New revision invalidates old export");
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  check("editing the completed revision removes the stale download");
  await page.getByRole("combobox", { name: /^Audio/ }).selectOption("muted");
  await downloadExport(page, primary, "explicitly-muted-video", {
    audio: false,
    ratio: [720, 1280],
    seconds: 2,
    caption: true,
  });
  check("explicit Mute audio produces no audio stream");

  await page.getByRole("combobox", { name: /^Audio/ }).selectOption("original");
  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles(photo);
  await expect(page.getByRole("button", { name: /^Select clip 2: source-photo.png/ })).toBeVisible();
  await expect(page.getByLabel("Photo duration (seconds)", { exact: true })).toBeEnabled();
  await page.getByLabel("Photo duration (seconds)", { exact: true }).fill("1");
  await page.getByLabel("Clip caption", { exact: false }).fill("PHOTO FIRST");
  await page.getByRole("button", { name: "Move earlier", exact: true }).click();
  await expect(page.getByRole("button", { name: /^Select clip 1: source-photo.png/ })).toBeVisible();
  await undo.click();
  await expect(page.getByRole("button", { name: /^Select clip 2: source-photo.png/ })).toBeVisible();
  await redo.click();
  await expect(page.getByRole("button", { name: /^Select clip 1: source-photo.png/ })).toBeVisible();
  check("Undo/Redo restores clip order before actual multi-clip export");
  for (const [index, format] of formats.entries()) {
    const sequence = await downloadExport(page, format, `ordered-sequence-${index + 1}`, { audio: true, ratio: [720, 1280], seconds: 3, caption: true, toneStart: 1.35 });
    sequence.sequenceEvidence = await assertPhotoThenVideo(sequence.path);
  }
  check("reordered photo-to-video sequence exports in every offered format with silent photo interval and original audio after the cut", { count: formats.length });
  // Remove only these synthetic clips to return to a single-photo cancellation fixture.
  await page.getByRole("button", { name: "Remove from edit", exact: true }).click();

  await undo.click();
  const restoredPhoto = page.getByRole("button", { name: /^Select clip 1: source-photo.png.*original file missing/ });
  await expect(restoredPhoto).toBeVisible();
  await restoredPhoto.click();
  await expect(page.getByLabel("Photo duration (seconds)", { exact: true })).toHaveValue("1");
  await expect(page.getByLabel("Clip caption", { exact: false })).toHaveValue("PHOTO FIRST");
  await expect(page.locator(".rp-editor-export-button")).toBeDisabled();
  const reconnect = async (file) => {
    const selectedFile = page.waitForEvent("filechooser");
    await page.getByRole("button", { name: "Reselect original file", exact: true }).click();
    await (await selectedFile).setFiles(file);
  };
  await reconnect(source);
  await expect(editor.getByRole("status").filter({ hasText: /This is a different file/ })).toBeVisible();
  await expect(page.locator(".rp-editor-export-button")).toBeDisabled();
  await reconnect(photo);
  await expect(editor.getByRole("status").filter({ hasText: "Original media verified and reconnected." })).toBeVisible();
  await expect(page.locator(".rp-editor-export-button")).toBeEnabled();
  await redo.click();
  await expect(page.getByRole("button", { name: /^Select clip .*source-photo.png/ })).toHaveCount(0);
  check("Undo removal restores exact cuts/text, requires verified original reselection, rejects a wrong file, and Redo removes it again");

  await page
    .getByRole("button", { name: "Remove from edit", exact: true })
    .click();
  await page
    .getByLabel("Add photos or videos", { exact: true })
    .setInputFiles(photo);
  await expect(
    page.getByRole("button", { name: /^Select clip 1: source-photo.png/ }),
  ).toBeVisible();
  await expect(
    page.getByLabel("Photo duration (seconds)", { exact: true }),
  ).toBeEnabled();
  await page.getByLabel("Photo duration (seconds)", { exact: true }).fill("2");
  await page
    .getByRole("combobox", { name: /^Aspect ratio/ })
    .selectOption("1:1");
  await page
    .getByLabel("Title overlay", { exact: true })
    .fill("Photo export fixture");
  await page.getByLabel("Clip caption", { exact: false }).fill("PHOTO EXPORT");
  await page.getByRole("combobox", { name: /^Audio/ }).selectOption("original");
  await downloadExport(page, primary, "square-photo", {
    audio: false,
    ratio: [960, 960],
    seconds: 2,
    caption: true,
  });
  await page.screenshot({
    path: join(artifacts, "photo-export-complete.png"),
    fullPage: true,
  });
  check(
    "photo exports as real square video with expected duration, burned text, and no synthetic audio",
  );

  await page.getByLabel("Photo duration (seconds)", { exact: true }).fill("8");
  await beginLongExport(page, primary);
  await page
    .getByLabel("Title overlay", { exact: true })
    .fill("Revision changed while recording");
  await expect(
    page.getByRole("button", { name: "Cancel export", exact: true }),
  ).toHaveCount(0, { timeout: 10_000 });
  await expect(
    editor
      .getByRole("status")
      .filter({ hasText: /Export cancelled because the edit changed/ }),
  ).toBeVisible();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  check(
    "changing edit revision during active recording aborts and produces no download",
  );

  await beginLongExport(page, primary);
  await page
    .getByRole("button", { name: "Cancel export", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Cancel export", exact: true }),
  ).toHaveCount(0, { timeout: 10_000 });
  await expect(
    editor
      .getByRole("status")
      .filter({ hasText: "Export cancelled. Your edit is unchanged." }),
  ).toBeVisible();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  check(
    "explicit cancellation during active recording preserves the edit and produces no download",
  );

  await beginLongExport(page, primary);
  await page.evaluate(() => {
    // Headless tabs stay visible even when backgrounded. Exercise the product's
    // real event listener with a scoped platform-state simulation, never its refs.
    Object.defineProperty(document, "hidden", {
      configurable: true,
      get: () => true,
    });
    try {
      document.dispatchEvent(new Event("visibilitychange"));
    } finally {
      delete document.hidden;
    }
  });
  await expect(
    page.getByRole("button", { name: "Cancel export", exact: true }),
  ).toHaveCount(0, { timeout: 10_000 });
  await expect(
    editor
      .getByRole("status")
      .filter({ hasText: /Export cancelled because the tab was hidden/ }),
  ).toBeVisible();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  await page.screenshot({
    path: join(artifacts, "cancelled-export.png"),
    fullPage: true,
  });
  check(
    "simulated hidden-tab visibilitychange aborts active recording without download",
  );

  await beginLongExport(page, primary);
  await page.getByRole("navigation", { name: "Studio navigation" }).getByRole("button", { name: "Content planner", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Content planner", level: 1, exact: true })).toBeVisible();
  await page.getByRole("navigation", { name: "Studio navigation" }).getByRole("button", { name: /^Video editor(?: NEW)?$/ }).click();
  await expect(editor).toBeVisible();
  await expect(page.getByRole("button", { name: "Cancel export", exact: true })).toHaveCount(0, { timeout: 10_000 });
  await expect(editor.getByRole("status").filter({ hasText: /Export cancelled because you left the video editor/ })).toBeVisible();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Reselect original file", exact: true })).toHaveCount(0);
  await expect(page.locator(".rp-editor-export-button")).toBeEnabled();
  check("leaving editor during active recording cancels the export while preserving verified local media");

  await beginLongExport(page, primary);
  const beforeUndoExport = await revision();
  await undo.click();
  await expect(page.getByRole("button", { name: "Cancel export", exact: true })).toHaveCount(0, { timeout: 10_000 });
  await expect(editor.getByRole("status").filter({ hasText: /Export cancelled because the edit changed/ })).toBeVisible();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  assert.equal(await revision(), beforeUndoExport + 1);
  await redo.click();
  await expect(page.locator(".rp-editor-download")).toHaveCount(0);
  check("Undo cancels active export and Redo cannot revive the interrupted output");

  // A fresh export after cancellations proves the encoder and UI recover.
  await page.getByLabel("Photo duration (seconds)", { exact: true }).fill("2");
  await downloadExport(page, primary, "after-cancellation", {
    audio: false,
    ratio: [960, 960],
    seconds: 2,
    caption: true,
  });
  check(
    "export succeeds after revision, explicit, visibility, and editor-navigation cancellation",
  );

  await Promise.all(responseChecks);
  assert.ok(
    receipt.servedAssets.some((asset) => /VideoEditor.*\.js$/.test(asset.path)),
    "The built editor chunk must be fetched and fingerprinted.",
  );
  assert.deepEqual(
    receipt.assetErrors,
    [],
    "All served asset bytes must match the frozen build.",
  );
  assert.deepEqual(
    receipt.externalRequests,
    [],
    "Editor checks must not contact customer accounts, providers, or cross-origin services.",
  );
  assert.deepEqual(
    receipt.disallowedRequests,
    [],
    "Editor checks permit only same-origin GET/HEAD requests, without redirects or WebSockets.",
  );
  assert.deepEqual(
    receipt.consoleErrors,
    [],
    "Browser console and uncaught errors must remain empty.",
  );
  check(
    "actual served editor bytes match dist; no external requests or uncaught browser errors",
  );
  await context.close();
  receipt.status = "passed";
} catch (error) {
  receipt.status = "failed";
  receipt.error =
    error instanceof Error ? (error.stack ?? error.message) : String(error);
  if (activePage && !activePage.isClosed())
    await activePage
      .screenshot({ path: join(artifacts, "failure.png"), fullPage: true })
      .catch(() => {});
  process.exitCode = 1;
} finally {
  if (beforeDist) {
    try {
      const afterDist = await fingerprintDist();
      assert.equal(
        afterDist.sha256,
        beforeDist.sha256,
        "dist changed during the browser run. Build once, then rerun against frozen bytes.",
      );
      receipt.finalDistSha256 = afterDist.sha256;
    } catch (error) {
      receipt.status = "failed";
      receipt.buildError = error.message;
      process.exitCode = 1;
    }
  }
  await browser?.close();
  if (previewProcess) {
    previewProcess.kill("SIGTERM");
    await Promise.race([
      new Promise((resolve) => previewProcess.once("exit", resolve)),
      new Promise((resolve) => setTimeout(resolve, 2000)),
    ]);
    if (previewProcess.exitCode === null) previewProcess.kill("SIGKILL");
  }
  receipt.finishedAt = new Date().toISOString();
  receipt.artifactHashes = [];
  for (const name of (await readdir(artifacts)).sort()) {
    const bytes = await readFile(join(artifacts, name));
    receipt.artifactHashes.push({
      name,
      bytes: bytes.length,
      sha256: sha256(bytes),
    });
  }
  try {
    await writeFile(
      join(artifacts, "receipt.json"),
      JSON.stringify(receipt, null, 2),
    );
  } catch (error) {
    // Keep the original launch/assertion error visible even if storage cannot
    // accept the receipt. Failure to save evidence still fails the run.
    receipt.status = "failed";
    receipt.artifactWriteError = error.message;
    process.exitCode = 1;
  }
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
