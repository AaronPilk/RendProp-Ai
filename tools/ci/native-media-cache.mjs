// Same-run CI cache inventory only. No install, download, restore, subprocess,
// relocation, publication or vendor-binary execution is implemented here.
import { constants } from "node:fs";
import { appendFile, chmod, lstat, mkdir, open, opendir, readFile, readlink, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { homedir, release } from "node:os";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const CACHE_LIMITS = Object.freeze({ formulae: 64, entries: 20_000, bytes: 1536 * 1024 ** 2,
  pathBytes: 4096, depth: 64, metadataBytes: 4 << 20, manifestBytes: 16 << 20 });
const PREFIX = "/opt/homebrew", REVISION = "1243", CHROME = "153.0.8010.12", PLAYWRIGHT = "1.63.0", FFMPEG = "9.0.2";
const SUFFIX = "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
const MODULE = fileURLToPath(import.meta.url), HASH = value => createHash("sha256").update(value).digest("hex");
const hex = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const commit = value => typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
const clean = value => typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= CACHE_LIMITS.pathBytes
  && !/[\x00-\x1f\x7f\\]/.test(value) && value.normalize("NFC") === value;
const within = (path, root) => path === root || path.startsWith(root + sep);
const exactKeys = (value, keys) => value && Object.getPrototypeOf(value) === Object.prototype
  && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
export class NativeCacheError extends Error { constructor(code) { super(code); this.code = code; } }
const need = (value, code) => { if (!value) throw new NativeCacheError(code); };
function canonical(value) {
  if (value === null || ["string", "boolean"].includes(typeof value)) return value;
  if (typeof value === "number") { need(Number.isSafeInteger(value), "CACHE_CANONICAL_VALUE_REFUSED"); return value; }
  if (Array.isArray(value)) return value.map(canonical);
  need(value && Object.getPrototypeOf(value) === Object.prototype, "CACHE_CANONICAL_VALUE_REFUSED");
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
}
export const manifestText = value => JSON.stringify(canonical(value), null, 2) + "\n";
export const manifestSha256 = value => HASH(manifestText(value));
const same = (a, b) => manifestText(a) === manifestText(b);
function pathValue(path) { need(clean(path) && isAbsolute(path) && resolve(path) === path, "CACHE_PATH_REFUSED"); return path; }
function policy(seams = {}) {
  need(exactKeys(seams, Object.keys(seams).filter(key => ["fixtureRoot", "homeDirectory", "system"].includes(key))), "CACHE_SEAM_REFUSED");
  need(seams.fixtureRoot !== undefined || seams.homeDirectory === undefined && seams.system === undefined, "CACHE_FIXTURE_ROOT_REQUIRED");
  const fixture = seams.fixtureRoot !== undefined;
  if (fixture) pathValue(seams.fixtureRoot);
  const home = pathValue(seams.homeDirectory ?? homedir());
  return { fixture, home, map: path => fixture ? join(seams.fixtureRoot, pathValue(path).slice(1)) : pathValue(path) };
}
async function physicalParents(path, p, include = false) {
  for (let at = include ? path : dirname(path); ; at = dirname(at)) {
    const stat = await lstat(p.map(at));
    need(stat.isDirectory() && !stat.isSymbolicLink(), "CACHE_PARENT_ALIAS_REFUSED");
    if (dirname(at) === at) break;
  }
}
const identity = stat => [stat.dev, stat.ino, stat.mode, stat.size, stat.nlink, stat.mtimeNs, stat.ctimeNs].map(String).join(":");
async function stableRead(path, p, maximum, collect = false) {
  await physicalParents(path, p);
  const current = await lstat(p.map(path), { bigint: true });
  need(current.isFile() && !current.isSymbolicLink() && current.nlink === 1n && current.size >= 0n && current.size <= BigInt(maximum), "CACHE_FILE_TYPE_OR_SIZE_REFUSED");
  need(Number.isInteger(constants.O_NOFOLLOW) && Number.isInteger(constants.O_NONBLOCK), "CACHE_SAFE_OPEN_UNAVAILABLE");
  const fd = await open(p.map(path), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await fd.stat({ bigint: true });
    need(identity(before) === identity(current), "CACHE_FILE_CHANGED");
    const hash = createHash("sha256"), parts = [], buffer = Buffer.alloc(Math.min(1 << 20, Math.max(1, Number(before.size))));
    let offset = 0;
    while (offset < Number(before.size)) {
      const { bytesRead } = await fd.read(buffer, 0, Math.min(buffer.length, Number(before.size) - offset), offset);
      need(bytesRead > 0, "CACHE_FILE_SHORT_READ"); hash.update(buffer.subarray(0, bytesRead));
      if (collect) parts.push(Buffer.from(buffer.subarray(0, bytesRead)));
      offset += bytesRead;
    }
    const after = await fd.stat({ bigint: true }), atPath = await lstat(p.map(path), { bigint: true });
    need(identity(before) === identity(after) && identity(before) === identity(atPath), "CACHE_FILE_CHANGED");
    return { bytes: offset, sha256: hash.digest("hex"), ...(collect ? { data: Buffer.concat(parts) } : {}) };
  } finally { await fd.close(); }
}
const CONTEXT_KEYS = ["repository", "sourceSha", "workflowSha", "runId", "runAttempt", "ref", "eventName", "imageOS", "imageVersion",
  "osRelease", "platform", "architecture", "nodeVersion", "workspace", "homeDirectory", "helperSha256", "lockSha256", "playwrightVersion", "browserRevision", "chromeVersion", "ffmpegVersion"];
function checkContext(context) {
  need(exactKeys(context, CONTEXT_KEYS) && context.repository === "AaronPilk/RendProp-Ai" && commit(context.sourceSha) && commit(context.workflowSha)
    && /^[1-9][0-9]{0,23}$/.test(context.runId) && /^[1-9][0-9]{0,7}$/.test(context.runAttempt)
    && clean(context.ref) && context.ref.startsWith("refs/") && ["pull_request", "push", "workflow_dispatch"].includes(context.eventName)
    && clean(context.imageOS) && clean(context.imageVersion) && clean(context.osRelease)
    && context.platform === "darwin" && context.architecture === "arm64" && /^v22\.[0-9]+\.[0-9]+$/.test(context.nodeVersion)
    && hex(context.helperSha256) && hex(context.lockSha256) && context.playwrightVersion === PLAYWRIGHT
    && context.browserRevision === REVISION && context.chromeVersion === CHROME && context.ffmpegVersion === FFMPEG, "CACHE_CONTEXT_REFUSED");
  pathValue(context.workspace); pathValue(context.homeDirectory);
}
export async function createCacheContext(environment = process.env, seams = {}) {
  const p = policy(seams), workspace = pathValue(environment.GITHUB_WORKSPACE);
  await physicalParents(workspace, p, true);
  const small = async relative => (await stableRead(join(workspace, relative), p, CACHE_LIMITS.metadataBytes, true)).data;
  const actualHead = (await small(".git/HEAD")).toString("ascii").trim();
  need(commit(actualHead) && actualHead === environment.MEDIA_SOURCE_SHA, "CACHE_CHECKOUT_SOURCE_DIFFER");
  const helper = await small("tools/ci/native-media-cache.mjs");
  need(HASH(helper) === HASH(await readFile(MODULE)), "CACHE_HELPER_SOURCE_DIFFER");
  const lock = await small("apps/studio/package-lock.json");
  const packageJson = JSON.parse((await small("apps/studio/node_modules/playwright/package.json")).toString("utf8"));
  const core = JSON.parse((await small("apps/studio/node_modules/playwright-core/package.json")).toString("utf8"));
  const browsers = JSON.parse((await small("apps/studio/node_modules/playwright-core/browsers.json")).toString("utf8"));
  const browser = browsers.browsers?.find(item => item.name === "chromium");
  need(packageJson.version === PLAYWRIGHT && core.version === PLAYWRIGHT && browser?.revision === REVISION && browser.browserVersion === CHROME, "CACHE_PLAYWRIGHT_METADATA_DIFFER");
  const system = seams.system ?? { platform: process.platform, architecture: process.arch, nodeVersion: process.version, osRelease: release() };
  const context = { repository: environment.GITHUB_REPOSITORY, sourceSha: actualHead, workflowSha: environment.MEDIA_WORKFLOW_SHA,
    runId: environment.GITHUB_RUN_ID, runAttempt: environment.GITHUB_RUN_ATTEMPT, ref: environment.GITHUB_REF, eventName: environment.GITHUB_EVENT_NAME,
    imageOS: environment.ImageOS, imageVersion: environment.ImageVersion, ...system, workspace, homeDirectory: p.home,
    helperSha256: HASH(helper), lockSha256: HASH(lock), playwrightVersion: packageJson.version, browserRevision: browser.revision,
    chromeVersion: browser.browserVersion, ffmpegVersion: FFMPEG };
  checkContext(context); return context;
}
function formulas(names) {
  need(Array.isArray(names) && names.length > 0 && names.length <= CACHE_LIMITS.formulae && new Set(names).size === names.length
    && names.includes("ffmpeg") && names.every(name => typeof name === "string" && /^[a-z0-9][a-z0-9+_.@-]{0,99}$/.test(name)), "CACHE_FORMULA_SET_REFUSED");
  return [...names].sort();
}
function destinations(context, browserRoot) {
  const expectedBrowser = join(context.homeDirectory, "Library/Caches/ms-playwright/chromium-" + REVISION);
  need(browserRoot === expectedBrowser, "CACHE_BROWSER_ROOT_DIFFER");
  return { manifestPath: join(context.workspace, ".ci-media-cache/manifest.json"), browserExecutable: join(browserRoot, SUFFIX),
    ffmpegExecutable: PREFIX + "/bin/ffmpeg", ffprobeExecutable: PREFIX + "/bin/ffprobe" };
}
async function rawLink(path, p) {
  await physicalParents(path, p);
  need((await lstat(p.map(path))).isSymbolicLink(), "CACHE_REQUIRED_LINK_REFUSED");
  const target = await readlink(p.map(path)); need(clean(target), "CACHE_LINK_TARGET_REFUSED"); return target;
}
async function inventory(roots, p) {
  const entries = []; let bytes = 0;
  const directories = roots.filter(root => root.type === "directory").map(root => root.path);
  const links = roots.filter(root => root.type === "symlink").map(root => root.path);
  const allowed = path => directories.some(root => within(path, root)) || links.some(root => within(path, root));
  // Structural ancestors are traversed only to reach exact selected roots. An
  // unknown sibling is never a reason to read a file outside the cache forest.
  const navigable = path => allowed(path) || roots.some(root => within(root.path, path));
  const resolveLink = async path => {
    const current = [], pending = path.split(sep).filter(Boolean); let hops = 0, steps = 0;
    while (pending.length) {
      need(++steps <= 8192, "CACHE_LINK_CYCLE_OR_DEPTH");
      const part = pending.shift();
      if (part === ".") continue;
      if (part === "..") {
        need(current.length > 0, "CACHE_LINK_ESCAPE"); current.pop();
        need(navigable(join(sep, ...current)), "CACHE_LINK_ESCAPE"); continue;
      }
      const cursor = join(sep, ...current, part); need(navigable(cursor), "CACHE_LINK_ESCAPE");
      const info = await lstat(p.map(cursor));
      if (info.isSymbolicLink()) {
        need(++hops <= 40, "CACHE_LINK_CYCLE_OR_DEPTH");
        const target = await readlink(p.map(cursor)); need(clean(target), "CACHE_LINK_TARGET_REFUSED");
        if (isAbsolute(target)) current.length = 0;
        pending.unshift(...target.split(sep).filter(Boolean));
      } else {
        need(pending.length === 0 || info.isDirectory(), "CACHE_LINK_PARENT_REFUSED"); current.push(part);
      }
    }
    const result = join(sep, ...current);
    need(directories.some(root => within(result, root)), "CACHE_LINK_ESCAPE"); return result;
  };
  const walk = async (path, depth) => {
    pathValue(path); need(depth <= CACHE_LIMITS.depth && entries.length < CACHE_LIMITS.entries, "CACHE_ENTRY_LIMIT");
    const info = await lstat(p.map(path), { bigint: true }), mode = Number(info.mode & 0o7777n).toString(8).padStart(4, "0");
    if (info.isSymbolicLink()) {
      // macOS creates symlinks with the current umask (commonly0755); Linux
      // commonly reports0777. Preserve that observed mode, never normalize it.
      need(["0555", "0755", "0777"].includes(mode), "CACHE_MODE_REFUSED"); const target = await readlink(p.map(path));
      need(clean(target), "CACHE_LINK_TARGET_REFUSED"); const resolvedPath = await resolveLink(path);
      entries.push({ path, type: "symlink", mode, target, resolvedPath });
    } else if (info.isDirectory()) {
      need((info.mode & 0o7022n) === 0n, "CACHE_MODE_REFUSED"); entries.push({ path, type: "directory", mode });
      for await (const entry of await opendir(p.map(path))) await walk(join(path, entry.name), depth + 1);
    } else {
      need(info.isFile() && info.nlink === 1n && (info.mode & 0o7022n) === 0n && info.size <= BigInt(CACHE_LIMITS.bytes - bytes), "CACHE_FILE_TYPE_OR_SIZE_REFUSED");
      const read = await stableRead(path, p, CACHE_LIMITS.bytes - bytes); bytes += read.bytes;
      entries.push({ path, type: "file", mode, bytes: read.bytes, sha256: read.sha256 });
    }
  };
  for (const root of roots) {
    await physicalParents(root.path, p);
    const info = await lstat(p.map(root.path));
    need(root.type === "directory" ? info.isDirectory() && !info.isSymbolicLink() : info.isSymbolicLink(), "CACHE_ROOT_TYPE_DIFFER");
    await walk(root.path, 0);
  }
  entries.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  need(new Set(entries.map(entry => entry.path)).size === entries.length, "CACHE_OVERLAPPING_ROOTS");
  return { entries, bytes };
}
export async function snapshotNativeCache({ context, formulaNames, browserRoot = join(context?.homeDirectory ?? "", "Library/Caches/ms-playwright/chromium-" + REVISION) }, seams = {}) {
  checkContext(context); const p = policy(seams), names = formulas(formulaNames);
  need(context.homeDirectory === p.home, "CACHE_HOME_DIFFER");
  const paths = destinations(context, browserRoot), roots = [{ path: browserRoot, type: "directory" }], formulae = [];
  for (const name of names) {
    const opt = join(PREFIX, "opt", name), target = await rawLink(opt, p), keg = resolve(dirname(opt), target), components = keg.split(sep);
    need(components.length === 6 && keg.startsWith(PREFIX + "/Cellar/" + name + "/") && /^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}$/.test(components.at(-1)), "CACHE_KEG_ROOT_REFUSED");
    need(name !== "ffmpeg" || keg === PREFIX + "/Cellar/ffmpeg/9.0.2_1", "CACHE_FFMPEG_KEG_VERSION_DIFFER");
    await physicalParents(keg, p, true);
    roots.push({ path: keg, type: "directory" }, { path: opt, type: "symlink" });
    const receipt = await stableRead(join(keg, "INSTALL_RECEIPT.json"), p, CACHE_LIMITS.metadataBytes, true);
    const receiptJson = JSON.parse(receipt.data.toString("utf8"));
    need(receiptJson && Object.getPrototypeOf(receiptJson) === Object.prototype && receipt.bytes > 0, "CACHE_INSTALLED_RECEIPT_REFUSED");
    const recipe = await stableRead(join(keg, ".brew", name + ".rb"), p, CACHE_LIMITS.metadataBytes);
    formulae.push({ name, version: components.at(-1), keg, opt, target, receiptSha256: receipt.sha256, recipeSha256: recipe.sha256 });
  }
  const ffmpeg = formulae.find(item => item.name === "ffmpeg");
  for (const name of ["ffmpeg", "ffprobe"]) {
    const path = join(PREFIX, "bin", name), target = await rawLink(path, p);
    const destination = resolve(dirname(path), target);
    need(destination === join(ffmpeg.keg, "bin", name) || destination === join(ffmpeg.opt, "bin", name), "CACHE_BINARY_LINK_REFUSED");
    roots.push({ path, type: "symlink" });
  }
  roots.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  const actual = await inventory(roots, p), browserEntry = actual.entries.find(entry => entry.path === paths.browserExecutable);
  for (const formula of formulae) need(actual.entries.find(entry => entry.path === formula.opt)?.resolvedPath === formula.keg, "CACHE_KEG_PHYSICAL_TARGET_DIFFER");
  need(browserEntry?.type === "file" && (Number.parseInt(browserEntry.mode, 8) & 0o111) !== 0, "CACHE_BROWSER_EXECUTABLE_REFUSED");
  for (const name of ["ffmpeg", "ffprobe"]) {
    const entry = actual.entries.find(item => item.path === join(ffmpeg.keg, "bin", name));
    need(entry?.type === "file" && (Number.parseInt(entry.mode, 8) & 0o111) !== 0, "CACHE_FFMPEG_EXECUTABLE_REFUSED");
    need(actual.entries.find(item => item.path === PREFIX + "/bin/" + name)?.resolvedPath === join(ffmpeg.keg, "bin", name), "CACHE_BINARY_PHYSICAL_TARGET_DIFFER");
  }
  const manifest = { schema: "rendprop-same-run-native-media-cache-v1", context: structuredClone(context), formulae, browserRoot, roots,
    ...actual, fixtureFilesystem: p.fixture, limitations: ["Selected runtime formulae are vendor prep facts; this inventory does not infer Mach-O closure or prove media health.",
      "No binary execution, install, network, restore, or timing/oracle change is performed."] };
  const encoded = manifestText(manifest); need(Buffer.byteLength(encoded) <= CACHE_LIMITS.manifestBytes, "CACHE_MANIFEST_LIMIT");
  const digest = HASH(encoded);
  return { manifest, manifestSha256: digest, cachePaths: [...roots.map(item => item.path), paths.manifestPath].sort(), ...paths,
    cacheKey: `rendprop-native-${context.runId}-${context.runAttempt}-${context.sourceSha}-${digest}` };
}
export async function verifyNativeCache({ manifest, expectedManifestSha256, expectedContext }, seams = {}) {
  need(hex(expectedManifestSha256), "CACHE_EXTERNAL_HASH_REQUIRED"); checkContext(expectedContext);
  need(exactKeys(manifest, ["schema", "context", "formulae", "browserRoot", "roots", "entries", "bytes", "fixtureFilesystem", "limitations"])
    && manifest.schema === "rendprop-same-run-native-media-cache-v1" && manifestSha256(manifest) === expectedManifestSha256, "CACHE_MANIFEST_HASH_DIFFER");
  need(same(manifest.context, expectedContext), "CACHE_CONTEXT_DIFFER");
  need(manifest.fixtureFilesystem === policy(seams).fixture, "CACHE_FIXTURE_ASSURANCE_DIFFER");
  const current = await snapshotNativeCache({ context: expectedContext, formulaNames: manifest.formulae.map(item => item.name), browserRoot: manifest.browserRoot }, seams);
  need(current.manifestSha256 === expectedManifestSha256, "CACHE_CONTENT_DIFFER");
  return { passed: true, manifestSha256: expectedManifestSha256, cacheKey: current.cacheKey, browserExecutable: current.browserExecutable,
    ffmpegExecutable: current.ffmpegExecutable, ffprobeExecutable: current.ffprobeExecutable, fixtureFilesystem: policy(seams).fixture };
}
async function outputs(values, environment) {
  if (!environment.GITHUB_OUTPUT) return;
  const text = Object.entries(values).map(([key, value]) => {
    const marker = "MEDIA_CACHE_" + HASH(String(value)); return `${key}<<${marker}\n${value}\n${marker}\n`;
  }).join("");
  await appendFile(environment.GITHUB_OUTPUT, text, { encoding: "utf8", flag: "a" });
}
export async function runCli(args, { environment = process.env, seams = {} } = {}) {
  const command = args[0];
  need(command === "record" && args.length === 1 || command === "verify" && args.length === 3 && args[1] === "--expected-sha256" && hex(args[2]), "CACHE_CLI_ARGUMENTS_REFUSED");
  const context = await createCacheContext(environment, seams), p = policy(seams), path = join(context.workspace, ".ci-media-cache/manifest.json");
  if (command === "record") {
    const names = environment.MEDIA_NATIVE_FORMULAE?.trim().split(/\r?\n/).map(value => value.trim());
    const result = await snapshotNativeCache({ context, formulaNames: names }, seams);
    await physicalParents(dirname(path), p); await mkdir(p.map(dirname(path)), { mode: 0o700 }); await chmod(p.map(dirname(path)), 0o700);
    await writeFile(p.map(path), manifestText(result.manifest), { flag: "wx", mode: 0o600 });
    await outputs({ "manifest-sha256": result.manifestSha256, "cache-paths": result.cachePaths.join("\n"), "cache-key": result.cacheKey,
      "browser-executable": result.browserExecutable }, environment);
    return { passed: true, command, manifestSha256: result.manifestSha256, cacheKey: result.cacheKey, cachePaths: result.cachePaths, browserExecutable: result.browserExecutable };
  }
  const directoryInfo = await lstat(p.map(dirname(path))), manifestInfo = await lstat(p.map(path));
  need(directoryInfo.isDirectory() && !directoryInfo.isSymbolicLink() && (directoryInfo.mode & 0o7022) === 0
    && manifestInfo.isFile() && !manifestInfo.isSymbolicLink() && (manifestInfo.mode & 0o7777) === 0o600, "CACHE_MANIFEST_PRIVACY_DIFFER");
  const read = await stableRead(path, p, CACHE_LIMITS.manifestBytes, true);
  need(read.sha256 === args[2], "CACHE_MANIFEST_HASH_DIFFER");
  const result = await verifyNativeCache({ manifest: JSON.parse(read.data.toString("utf8")), expectedManifestSha256: args[2], expectedContext: context }, seams);
  await outputs({ "verified-manifest-sha256": result.manifestSha256, "browser-executable": result.browserExecutable,
    "ffmpeg-executable": result.ffmpegExecutable, "ffprobe-executable": result.ffprobeExecutable }, environment);
  return { ...result, command };
}
if (process.argv[1] && resolve(process.argv[1]) === MODULE) {
  runCli(process.argv.slice(2)).then(result => process.stdout.write(JSON.stringify(result) + "\n")).catch(error => {
    process.stderr.write(JSON.stringify({ passed: false, code: error instanceof NativeCacheError ? error.code : "CACHE_IO_OR_METADATA_REFUSED" }) + "\n"); process.exitCode = 1;
  });
}
