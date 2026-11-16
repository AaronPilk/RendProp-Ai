// Narrow recorded Chromium1243 code identity. No process, network, signing or browser execution.
import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
export const IMAGE = Object.freeze({ bytes: 52112, sha256: '8319963f6625accf51c0dd4f55091ceaf9f09ed39e7a52fed4fae12b2a6b668a' });
export const METADATA_LIMIT = 8192;
const SUFFIX = '/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASELINE = Object.freeze({
  Identifier: 'Google Chrome for Testing', Format: 'app bundle with Mach-O thin (arm64)',
  'CodeDirectory v': '20400 size=536 flags=0x20002(adhoc,linker-signed) hashes=13+0 location=embedded',
  VersionPlatform: '1', VersionMin: '851968', VersionSDK: '1705216',
  'Hash type': 'sha256 size=32', 'CandidateCDHash sha256': 'e52e966fc44a8c089bf511260b50fd6320e657dc',
  'CandidateCDHashFull sha256': 'e52e966fc44a8c089bf511260b50fd6320e657dca67b72d443b85482d3f0ffae',
  'Hash choices': 'sha256', CMSDigest: 'e52e966fc44a8c089bf511260b50fd6320e657dca67b72d443b85482d3f0ffae',
  CMSDigestType: '2', 'Executable Segment base': '0', 'Executable Segment limit': '16384',
  'Executable Segment flags': '0x1', 'Page size': '4096', CDHash: 'e52e966fc44a8c089bf511260b50fd6320e657dc',
  Signature: 'adhoc', 'Info.plist': 'not bound', TeamIdentifier: 'not set', 'Sealed Resources': 'none', 'Internal requirements': 'none'
});
export class BrowserSignatureError extends Error { constructor(code) { super(code); this.code = code; } }
const need = (ok, code) => { if (!ok) throw new BrowserSignatureError(code); };
function knownPath(path) {
  need(typeof path === 'string' && path.length <= 4096 && /^[\x20-\x7e]+$/.test(path) && isAbsolute(path)
    && resolve(path) === path && path.endsWith(SUFFIX), 'KNOWN_EXECUTABLE_PATH_REQUIRED');
  return path;
}
export function parseBrowserSignature(metadata, knownExecutable) {
  knownPath(knownExecutable);
  need(typeof metadata === 'string' && Buffer.byteLength(metadata) <= METADATA_LIMIT && /^[\x20-\x7e\n]+$/.test(metadata), 'METADATA_BOUNDS_OR_CONTROL');
  const expected = { Executable: knownExecutable, ...BASELINE }, seen = new Set();
  const lines = metadata.endsWith('\n') ? metadata.slice(0, -1).split('\n') : metadata.split('\n');
  for (const line of lines) {
    const index = line.indexOf('='); need(index > 0, 'METADATA_SYNTAX_REFUSED');
    const key = line.slice(0, index), value = line.slice(index + 1);
    need(!seen.has(key), 'METADATA_DUPLICATE_FIELD'); seen.add(key);
    need(key !== 'Authority', 'PUBLISHER_AUTHORITY_CONTRADICTS_ADHOC');
    need(Object.hasOwn(expected, key), 'METADATA_UNKNOWN_FIELD');
    need(value === expected[key], 'RECORDED_CODE_IDENTITY_DIFFER');
  }
  need(seen.size === Object.keys(expected).length, 'METADATA_INCOMPLETE');
  return { executable: knownExecutable, codeIdentityOnly: true, publisherVerified: false, sealedResources: false,
    platformCodeVerificationPerformed: false, resourcePolicy: 'unsealed-vendor-bundle; full-source-run-bound-manifest-required',
    cdHash: BASELINE.CDHash, signature: 'adhoc', teamIdentifier: null };
}
export function assertPinnedImage(record) {
  need(record?.bytes === IMAGE.bytes && record?.sha256 === IMAGE.sha256, 'PINNED_EXECUTABLE_BYTES_DIFFER');
  return { bytes: IMAGE.bytes, sha256: IMAGE.sha256 };
}
const FIELDS = ['dev', 'ino', 'mode', 'size', 'nlink', 'mtimeNs', 'ctimeNs'];
export function assertStableStats(...stats) {
  need(stats.length >= 2 && stats.every(s => s && FIELDS.every(k => typeof s[k] === 'bigint')), 'STABLE_STAT_SHAPE_REQUIRED');
  need(stats.every(s => FIELDS.every(k => s[k] === stats[0][k])), 'EXECUTABLE_CHANGED');
}
async function parents(path) {
  for (let at = dirname(path); ; at = dirname(at)) {
    const info = await lstat(at); need(info.isDirectory() && !info.isSymbolicLink(), 'EXECUTABLE_PARENT_ALIAS');
    if (dirname(at) === at) break;
  }
}
export async function inspectPinnedExecutable(executable) {
  knownPath(executable); await parents(executable);
  const before = await lstat(executable, { bigint: true });
  need(before.isFile() && !before.isSymbolicLink() && before.nlink === 1n && before.size === BigInt(IMAGE.bytes)
    && (before.mode & 0o7022n) === 0n, 'EXECUTABLE_TYPE_SIZE_OR_MODE_DIFFER');
  need(Number.isInteger(constants.O_NOFOLLOW) && Number.isInteger(constants.O_NONBLOCK), 'SAFE_READ_UNAVAILABLE');
  const fd = await open(executable, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    assertStableStats(before, await fd.stat({ bigint: true }));
    const hash = createHash('sha256'), buffer = Buffer.alloc(8192); let bytes = 0;
    while (bytes < IMAGE.bytes) {
      const { bytesRead } = await fd.read(buffer, 0, Math.min(buffer.length, IMAGE.bytes - bytes), bytes);
      need(bytesRead > 0, 'EXECUTABLE_SHORT_READ'); hash.update(buffer.subarray(0, bytesRead)); bytes += bytesRead;
    }
    assertStableStats(before, await fd.stat({ bigint: true }), await lstat(executable, { bigint: true }));
    await parents(executable); return assertPinnedImage({ bytes, sha256: hash.digest('hex') });
  } finally { await fd.close(); }
}
export async function readMetadata(input) {
  const chunks = []; let bytes = 0;
  for await (const chunk of input) {
    need(Buffer.isBuffer(chunk), 'STDIN_BYTES_REQUIRED'); bytes += chunk.length;
    need(bytes <= METADATA_LIMIT, 'METADATA_LIMIT'); chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}
export function executableArgument(args) {
  need(Array.isArray(args) && args.length === 2 && args[0] === '--executable', 'EXACT_ARGUMENTS_REQUIRED');
  return knownPath(args[1]);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  (async () => {
    const executable = executableArgument(process.argv.slice(2));
    const policy = parseBrowserSignature(await readMetadata(process.stdin), executable);
    const image = await inspectPinnedExecutable(executable);
    process.stdout.write(JSON.stringify({ passed: true, ...policy, image }) + '\n');
  })().catch(error => { process.stderr.write(JSON.stringify({ passed: false,
    code: error instanceof BrowserSignatureError ? error.code : 'EXECUTABLE_IO_REFUSED' }) + '\n'); process.exitCode = 1; });
}
