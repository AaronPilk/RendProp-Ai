import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { createHash } from "node:crypto";
import { chmod, link, lstat, mkdir, mkdtemp, readFile, realpath, rename, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { CACHE_LIMITS, NativeCacheError, createCacheContext, manifestSha256, manifestText, runCli, snapshotNativeCache, verifyNativeCache } from "./native-media-cache.mjs";

const sha = data => createHash("sha256").update(data).digest("hex"), source = await readFile(new URL("./native-media-cache.mjs", import.meta.url));
let savedSpawn, savedFetch, processes = 0, requests = 0;
before(() => {
  savedSpawn = childProcess.spawn; savedFetch = globalThis.fetch;
  childProcess.spawn = () => { processes++; throw new Error("CLOSED_CACHE_PROCESS_REFUSED"); };
  globalThis.fetch = () => { requests++; throw new Error("CLOSED_CACHE_NETWORK_REFUSED"); };
  syncBuiltinESMExports();
});
after(() => { childProcess.spawn = savedSpawn; globalThis.fetch = savedFetch; syncBuiltinESMExports(); assert.equal(processes, 0); assert.equal(requests, 0); });

async function fixture({ absoluteOpt = false } = {}) {
  const fixtureRoot = await realpath(await mkdtemp(join(tmpdir(), "rendprop-native-cache-closed-")));
  const home = "/Users/runner", workspace = home + "/work/RendProp-Ai/RendProp-Ai", prefix = "/opt/homebrew";
  const map = path => join(fixtureRoot, path.slice(1));
  const file = async (path, bytes, mode = 0o644) => {
    await mkdir(dirname(map(path)), { recursive: true });
    try { await chmod(map(path), 0o600); } catch (error) { if (error.code !== "ENOENT") throw error; }
    await writeFile(map(path), bytes); await chmod(map(path), mode);
  };
  const ln = async (path, target) => { await mkdir(dirname(map(path)), { recursive: true }); await symlink(target, map(path)); };
  const browserRoot = home + "/Library/Caches/ms-playwright/chromium-1243";
  const executable = browserRoot + "/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
  await file(executable, "synthetic Chrome bytes, never executed", 0o755);
  const framework = browserRoot + "/chrome-mac-arm64/Google Chrome for Testing.app/Contents/Frameworks/Fixture.framework";
  await file(framework + "/Versions/A/Fixture", "read-only vendor framework", 0o555);
  await ln(framework + "/Versions/Current", "A"); await ln(framework + "/Fixture", "Versions/Current/Fixture");
  await file(browserRoot + "/INSTALLATION_COMPLETE", "", 0o444);
  const formulaNames = ["ffmpeg", "libfixture"];
  const kegs = { ffmpeg: prefix + "/Cellar/ffmpeg/9.0.2_1", libfixture: prefix + "/Cellar/libfixture/1.0" };
  for (const name of formulaNames) {
    await file(kegs[name] + "/INSTALL_RECEIPT.json", JSON.stringify({ source: { tap: "homebrew/core" }, runtime_dependencies: [] }));
    await file(kegs[name] + "/.brew/" + name + ".rb", "# synthetic installed recipe\n", 0o444);
    await ln(prefix + "/opt/" + name, absoluteOpt ? kegs[name] : "../Cellar/" + name + "/" + kegs[name].split("/").at(-1));
  }
  for (const name of ["ffmpeg", "ffprobe"]) { await file(kegs.ffmpeg + "/bin/" + name, "synthetic " + name, 0o755); await ln(prefix + "/bin/" + name, "../Cellar/ffmpeg/9.0.2_1/bin/" + name); }
  await file(kegs.libfixture + "/lib/libfixture.1.dylib", "synthetic dylib, never loaded", 0o444);
  await ln(kegs.libfixture + "/lib/libfixture.dylib", "libfixture.1.dylib");
  await file(kegs.libfixture + "/share/data/default.conf", "public vendor default, not owner config");
  await file(workspace + "/.git/HEAD", "a".repeat(40) + "\n");
  await file(workspace + "/tools/ci/native-media-cache.mjs", source);
  await file(workspace + "/apps/studio/package-lock.json", '{"lockfileVersion":3}\n');
  for (const name of ["playwright", "playwright-core"]) await file(workspace + "/apps/studio/node_modules/" + name + "/package.json", '{"version":"1.63.0"}\n');
  await file(workspace + "/apps/studio/node_modules/playwright-core/browsers.json", JSON.stringify({ browsers: [{ name: "chromium", revision: "1243", browserVersion: "153.0.8010.12" }] }));
  const environment = { GITHUB_WORKSPACE: workspace, MEDIA_SOURCE_SHA: "a".repeat(40), MEDIA_WORKFLOW_SHA: "b".repeat(40),
    GITHUB_REPOSITORY: "AaronPilk/RendProp-Ai", GITHUB_RUN_ID: "123456789", GITHUB_RUN_ATTEMPT: "1", GITHUB_REF: "refs/pull/40/merge", GITHUB_EVENT_NAME: "pull_request",
    ImageOS: "macos26", ImageVersion: "20261015.1", MEDIA_NATIVE_FORMULAE: formulaNames.join("\n") };
  const seams = { fixtureRoot, homeDirectory: home, system: { platform: "darwin", architecture: "arm64", nodeVersion: "v22.20.0", osRelease: "25.0.0" } };
  const context = await createCacheContext(environment, seams), options = { context, formulaNames, browserRoot };
  const snapshot = () => snapshotNativeCache(options, seams);
  const verify = (manifest, expectedManifestSha256, expectedContext = context) => verifyNativeCache({ manifest, expectedManifestSha256, expectedContext }, seams);
  return { fixtureRoot, home, workspace, prefix, map, file, ln, browserRoot, executable, framework, formulaNames, kegs, environment, seams, context, options, snapshot, verify };
}

test("same-run snapshots preserve native paths, full selected kegs, framework symlinks and read-only vendor modes", async () => {
  const f = await fixture(), result = await f.snapshot();
  assert.equal(result.manifest.fixtureFilesystem, true); assert.equal(result.manifestSha256, sha(manifestText(result.manifest)));
  assert.equal(result.manifest.context.sourceSha, "a".repeat(40)); assert.equal(result.manifest.context.helperSha256, sha(source));
  assert.equal(result.browserExecutable, f.executable); assert.equal(result.ffmpegExecutable, "/opt/homebrew/bin/ffmpeg");
  assert(result.cachePaths.includes(f.browserRoot)); assert(result.cachePaths.includes(f.kegs.ffmpeg));
  assert(result.cachePaths.includes(f.workspace + "/.ci-media-cache/manifest.json"));
  assert(!result.cachePaths.includes(f.prefix)); assert(!result.cachePaths.includes(f.prefix + "/etc"));
  assert(!result.manifest.entries.some(entry => entry.path.includes(".ci-media-cache")));
  const modes = new Map(result.manifest.entries.map(entry => [entry.path, entry.mode]));
  assert.equal(modes.get(f.browserRoot + "/INSTALLATION_COMPLETE"), "0444");
  assert.equal(modes.get(f.framework + "/Versions/A/Fixture"), "0555");
  assert.equal((await f.verify(result.manifest, result.manifestSha256)).passed, true);
  assert.equal(requests, 0); assert.equal(processes, 0);
});
test("absolute opt targets are accepted only when they resolve to the same exact physical native keg", async () => {
  const f = await fixture({ absoluteOpt: true }), result = await f.snapshot(); assert.equal((await f.verify(result.manifest, result.manifestSha256)).passed, true);
});
test("consumer requires an external trusted hash and exact same-run source/OS/Node-minor context", async () => {
  const f = await fixture(), result = await f.snapshot();
  for (const hash of [undefined, null, "", "0".repeat(64)]) await assert.rejects(f.verify(result.manifest, hash), NativeCacheError);
  for (const key of ["sourceSha", "workflowSha", "runId", "ref", "imageOS", "osRelease", "lockSha256", "nodeVersion"]) {
    const changed = structuredClone(f.context); changed[key] = key.endsWith("Sha") ? "c".repeat(40) : key === "lockSha256" ? "c".repeat(64) : key === "nodeVersion" ? "v22.21.0" : key === "runId" ? "2" : changed[key] + "x";
    await assert.rejects(f.verify(result.manifest, result.manifestSha256, changed), NativeCacheError);
  }
});
test("a failed-job rerun accepts an earlier sealed cache only within the exact run and source", async () => {
  const f = await fixture(), result = await f.snapshot(), consumer = structuredClone(f.context);
  consumer.runAttempt = "2";
  assert.equal((await f.verify(result.manifest, result.manifestSha256, consumer)).passed, true);
  for (const change of [
    { runId: "987654321" }, { sourceSha: "c".repeat(40) }, { workflowSha: "c".repeat(40) },
    { helperSha256: "c".repeat(64) }, { lockSha256: "c".repeat(64) },
  ]) await assert.rejects(f.verify(result.manifest, result.manifestSha256, { ...consumer, ...change }), { code: "CACHE_CONTEXT_DIFFER" });
  const future = structuredClone(result.manifest); future.context.runAttempt = "3";
  await assert.rejects(f.verify(future, manifestSha256(future), consumer), { code: "CACHE_CONTEXT_DIFFER" });
  await f.file(f.kegs.libfixture + "/lib/libfixture.1.dylib", "stale vendor bytes", 0o444);
  await assert.rejects(f.verify(result.manifest, result.manifestSha256, consumer), { code: "CACHE_CONTENT_DIFFER" });
});
test("same macOS release on a newer runner image accepts only byte-identical cache content", async () => {
  const f = await fixture(), result = await f.snapshot(), consumer = structuredClone(f.context);
  consumer.imageVersion = "20261021.0445.8";
  const verified = await f.verify(result.manifest, result.manifestSha256, consumer);
  assert.equal(verified.preparedImageVersion, "20261015.1");
  assert.equal(verified.consumerImageVersion, consumer.imageVersion);
  assert.equal(verified.manifestSha256, result.manifestSha256);
  await f.file(f.kegs.libfixture + "/lib/libfixture.1.dylib", "changed on new image", 0o444);
  await assert.rejects(f.verify(result.manifest, result.manifestSha256, consumer), { code: "CACHE_CONTENT_DIFFER" });
});
test("Node patch drift across same-run jobs keeps the cache bound to exact vendor bytes", async () => {
  const f = await fixture(), result = await f.snapshot(), consumer = structuredClone(f.context);
  consumer.nodeVersion = "v22.20.1";
  const verified = await f.verify(result.manifest, result.manifestSha256, consumer);
  assert.equal(verified.preparedNodeVersion, "v22.20.0");
  assert.equal(verified.consumerNodeVersion, consumer.nodeVersion);
  await f.file(f.kegs.libfixture + "/lib/libfixture.1.dylib", "changed with Node patch", 0o444);
  await assert.rejects(f.verify(result.manifest, result.manifestSha256, consumer), { code: "CACHE_CONTENT_DIFFER" });
});
test("changed, extra, missing and mode-altered vendor entries fail the full byte/type inventory", async () => {
  for (const change of [
    async f => f.file(f.kegs.libfixture + "/lib/libfixture.1.dylib", "changed bytes", 0o444),
    async f => f.file(f.kegs.libfixture + "/lib/extra.dylib", "unexpected extra"),
    async f => rename(f.map(f.kegs.libfixture + "/lib/libfixture.1.dylib"), f.map(f.kegs.libfixture + "/lib/renamed.dylib")),
    async f => chmod(f.map(f.framework + "/Versions/A/Fixture"), 0o755),
  ]) {
    const f = await fixture(), result = await f.snapshot(); await change(f);
    await assert.rejects(f.verify(result.manifest, result.manifestSha256));
  }
});
test("cross-job inode and timestamp changes with identical vendor bytes and modes remain valid", async () => {
  const f = await fixture(), result = await f.snapshot(), path = f.kegs.libfixture + "/share/data/default.conf";
  const data = await readFile(f.map(path)); await rename(f.map(path), f.map(path) + ".preserved-original");
  // The preserved file is moved outside the selected roots; cache restore makes
  // new inodes as well. It is retained in the test's own evidence directory.
  await rename(f.map(path) + ".preserved-original", join(f.fixtureRoot, "preserved-original")); await f.file(path, data);
  assert.equal((await f.verify(result.manifest, result.manifestSha256)).passed, true);
});
test("links outside selected native roots, dangling links, aliases and cycles refuse without reading outside payloads", async () => {
  for (const target of ["/etc/passwd", "/opt/homebrew/etc/private.conf", "missing", "loop"]) {
    const f = await fixture(); await f.ln(f.kegs.libfixture + "/lib/loop", target);
    await assert.rejects(f.snapshot());
  }
  const f = await fixture(), result = await f.snapshot();
  await rename(f.map(f.prefix + "/opt/libfixture"), join(f.fixtureRoot, "preserved-opt-link"));
  await f.ln(f.prefix + "/opt/libfixture", "../Cellar/ffmpeg/9.0.2_1");
  await assert.rejects(f.verify(result.manifest, result.manifestSha256), { code: "CACHE_KEG_ROOT_REFUSED" });
});
test("hard links, setuid and writable vendor modes refuse before cache acceptance", async () => {
  for (const mode of [0o4755, 0o2755, 0o1777, 0o666]) {
    const f = await fixture(); await chmod(f.map(f.kegs.libfixture + "/lib/libfixture.1.dylib"), mode); await assert.rejects(f.snapshot());
  }
  const f = await fixture(); await link(f.map(f.kegs.libfixture + "/lib/libfixture.1.dylib"), join(f.fixtureRoot, "preserved-hard-link"));
  await assert.rejects(f.snapshot(), { code: "CACHE_FILE_TYPE_OR_SIZE_REFUSED" });
});
test("formula lists, FFmpeg keg version, browser root and required binary links are pinned", async () => {
  const f = await fixture();
  for (const names of [[], ["libfixture"], ["ffmpeg", "ffmpeg"], ["ffmpeg", "../etc"], Array.from({ length: 65 }, (_, i) => "f" + i)]) {
    await assert.rejects(snapshotNativeCache({ ...f.options, formulaNames: names }, f.seams), { code: "CACHE_FORMULA_SET_REFUSED" });
  }
  await assert.rejects(snapshotNativeCache({ ...f.options, browserRoot: f.home + "/Library/Caches/ms-playwright" }, f.seams), { code: "CACHE_BROWSER_ROOT_DIFFER" });
  await rename(f.map(f.prefix + "/opt/ffmpeg"), join(f.fixtureRoot, "preserved-ffmpeg-opt"));
  await f.ln(f.prefix + "/opt/ffmpeg", "../Cellar/ffmpeg/9.0.2_2");
  await assert.rejects(f.snapshot(), { code: "CACHE_FFMPEG_KEG_VERSION_DIFFER" });
  const g = await fixture(); await rename(g.map(g.prefix + "/bin/ffmpeg"), join(g.fixtureRoot, "preserved-bin")); await g.ln(g.prefix + "/bin/ffmpeg", "../Cellar/libfixture/1.0/bin/ffmpeg");
  await assert.rejects(g.snapshot(), { code: "CACHE_BINARY_LINK_REFUSED" });
});
test("actual source and installed Playwright metadata must match before a manifest can be recorded", async () => {
  for (const change of [
    async f => { f.environment.MEDIA_SOURCE_SHA = "c".repeat(40); },
    async f => f.file(f.workspace + "/tools/ci/native-media-cache.mjs", "wrong helper"),
    async f => f.file(f.workspace + "/apps/studio/node_modules/playwright/package.json", '{"version":"1.62.0"}'),
    async f => f.file(f.workspace + "/apps/studio/node_modules/playwright-core/browsers.json", '{"browsers":[{"name":"chromium","revision":"1242","browserVersion":"153.0.8010.12"}]}'),
  ]) { const f = await fixture(); await change(f); await assert.rejects(createCacheContext(f.environment, f.seams)); }
});
test("record and verify CLI use a private separate manifest and emit no verified outputs before full audit", async () => {
  const f = await fixture(), output = join(f.fixtureRoot, "github-output"); f.environment.GITHUB_OUTPUT = output;
  const record = await runCli(["record"], { environment: f.environment, seams: f.seams });
  const path = f.workspace + "/.ci-media-cache/manifest.json";
  assert.equal((await lstat(f.map(path))).mode & 0o777, 0o600); assert.equal((await lstat(f.map(dirname(path)))).mode & 0o777, 0o700);
  const before = await readFile(output, "utf8"); assert(before.includes("manifest-sha256<<")); assert(before.includes("cache-paths<<")); assert(before.includes("cache-key<<"));
  assert(!before.includes("verified-manifest-sha256"));
  assert.equal((await runCli(["verify", "--expected-sha256", record.manifestSha256], { environment: f.environment, seams: f.seams })).passed, true);
  f.environment.GITHUB_RUN_ATTEMPT = "2";
  assert.equal((await runCli(["verify", "--expected-sha256", record.manifestSha256], { environment: f.environment, seams: f.seams })).passed, true);
  const verifiedOutput = await readFile(output, "utf8"); assert(verifiedOutput.includes("verified-manifest-sha256<<")); assert(verifiedOutput.includes("ffprobe-executable<<"));
  await f.file(f.kegs.libfixture + "/lib/extra.dylib", "bad");
  await assert.rejects(runCli(["verify", "--expected-sha256", record.manifestSha256], { environment: f.environment, seams: f.seams }));
  assert.equal(await readFile(output, "utf8"), verifiedOutput, "A failed verification cannot emit a fresh acceptance");
});
test("cache file values alone cannot authorize verify, and a fixture manifest never passes a real-filesystem assurance", async () => {
  const f = await fixture(), result = await f.snapshot();
  await assert.rejects(runCli(["verify"], { environment: f.environment, seams: f.seams }), { code: "CACHE_CLI_ARGUMENTS_REFUSED" });
  await assert.rejects(verifyNativeCache({ manifest: result.manifest, expectedManifestSha256: result.manifestSha256, expectedContext: f.context }), { code: "CACHE_FIXTURE_ASSURANCE_DIFFER" });
  await assert.rejects(runCli(["record", "--install-fallback"], { environment: f.environment, seams: f.seams }), { code: "CACHE_CLI_ARGUMENTS_REFUSED" });
});
test("limits, same-run keys and metadata-only scope remain explicit and bounded", async () => {
  assert.equal(CACHE_LIMITS.formulae, 64); assert.equal(CACHE_LIMITS.entries, 20_000); assert.equal(CACHE_LIMITS.bytes, 1536 * 1024 ** 2);
  const f = await fixture(), result = await f.snapshot();
  assert(result.cacheKey.includes(f.context.runId)); assert(result.cacheKey.includes(f.context.runAttempt)); assert(result.cacheKey.includes(f.context.sourceSha)); assert(result.cacheKey.endsWith(result.manifestSha256));
  assert(result.cacheKey.length < 512); assert(result.manifest.limitations.some(text => text.includes("does not infer Mach-O closure")));
  assert.equal(requests, 0); assert.equal(processes, 0);
});
test("installed receipt and recipe changes are part of the sealed vendor inventory", async () => {
  for (const path of ["INSTALL_RECEIPT.json", ".brew/libfixture.rb"]) {
    const f = await fixture(), result = await f.snapshot(); await f.file(f.kegs.libfixture + "/" + path, path.endsWith(".json") ? '{"different":true}' : "changed recipe");
    await assert.rejects(f.verify(result.manifest, result.manifestSha256), { code: "CACHE_CONTENT_DIFFER" });
  }
});
test("no externally hashed manifest can expand the allowed root policy into owner configuration", async () => {
  const f = await fixture(), result = await f.snapshot(), changed = structuredClone(result.manifest);
  changed.roots.push({ path: "/opt/homebrew/etc", type: "directory" });
  changed.entries.push({ path: "/opt/homebrew/etc/private.conf", type: "file", mode: "0600", bytes: 1, sha256: sha("x") });
  await assert.rejects(f.verify(changed, manifestSha256(changed)), { code: "CACHE_CONTENT_DIFFER" });
  assert.equal(requests, 0); assert.equal(processes, 0);
});
test("physical root ancestors and excessive tree depth fail closed", async () => {
  const f = await fixture(); await rename(f.map(f.browserRoot), f.map(f.browserRoot) + ".preserved"); await f.ln(f.browserRoot, f.browserRoot + ".preserved");
  await assert.rejects(f.snapshot(), { code: "CACHE_ROOT_TYPE_DIFFER" });
  const g = await fixture(); await g.file(g.kegs.libfixture + "/" + Array.from({ length: 65 }, () => "d").join("/") + "/file", "over-depth");
  await assert.rejects(g.snapshot(), { code: "CACHE_ENTRY_LIMIT" });
});
test("CLI verification enforces the manifest's private file and directory modes", async () => {
  for (const which of ["file", "directory"]) {
    const f = await fixture(), result = await runCli(["record"], { environment: f.environment, seams: f.seams });
    const path = f.workspace + "/.ci-media-cache/manifest.json"; await chmod(f.map(which === "file" ? path : dirname(path)), which === "file" ? 0o755 : 0o777);
    await assert.rejects(runCli(["verify", "--expected-sha256", result.manifestSha256], { environment: f.environment, seams: f.seams }), { code: "CACHE_MANIFEST_PRIVACY_DIFFER" });
  }
});
test("a file-only cache restore may recreate a safe parent at0755 while the manifest stays0600", async () => {
  const f = await fixture(), result = await runCli(["record"], { environment: f.environment, seams: f.seams });
  await chmod(f.map(f.workspace + "/.ci-media-cache"), 0o755);
  assert.equal((await runCli(["verify", "--expected-sha256", result.manifestSha256], { environment: f.environment, seams: f.seams })).passed, true);
});
test("symlink dot traversal follows physical components before dotdot and never transits unknown selected-root siblings", async () => {
  const f = await fixture();
  await f.ln(f.kegs.libfixture + "/lib/jump", f.kegs.ffmpeg);
  await f.file(f.prefix + "/Cellar/ffmpeg/libfixture.1.dylib", "outside selected native keg, never accepted");
  // Lexical normalization lands on libfixture/1.0/lib/libfixture.1.dylib.
  // Physical lookup first follows jump, so '..' leaves ffmpeg/9.0.2_1.
  await f.ln(f.kegs.libfixture + "/lib/tricky", "jump/../libfixture.1.dylib");
  await assert.rejects(f.snapshot(), { code: "CACHE_LINK_ESCAPE" });
});
