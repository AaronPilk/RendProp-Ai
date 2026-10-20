import test from 'node:test';
import { constants } from 'node:fs';
import fsPromises from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, chmod, symlink, link, realpath, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { IMAGE, METADATA_LIMIT, parseBrowserSignature, assertPinnedImage, assertStableStats,
  inspectPinnedExecutable, readMetadata, executableArgument } from './browser-signature-policy.mjs';
const SUFFIX = '/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const EXE = '/closed/person' + SUFFIX;
const GOLD = `Executable=${EXE}
Identifier=Google Chrome for Testing
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=536 flags=0x20002(adhoc,linker-signed) hashes=13+0 location=embedded
VersionPlatform=1
VersionMin=851968
VersionSDK=1705216
Hash type=sha256 size=32
CandidateCDHash sha256=e52e966fc44a8c089bf511260b50fd6320e657dc
CandidateCDHashFull sha256=e52e966fc44a8c089bf511260b50fd6320e657dca67b72d443b85482d3f0ffae
Hash choices=sha256
CMSDigest=e52e966fc44a8c089bf511260b50fd6320e657dca67b72d443b85482d3f0ffae
CMSDigestType=2
Executable Segment base=0
Executable Segment limit=16384
Executable Segment flags=0x1
Page size=4096
CDHash=e52e966fc44a8c089bf511260b50fd6320e657dc
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
Internal requirements=none
`;
const fails = code => error => error?.code === code;
test('approved image and metadata cap are independent literals', () => {
  assert.deepEqual(IMAGE, { bytes: 52112, sha256: '8319963f6625accf51c0dd4f55091ceaf9f09ed39e7a52fed4fae12b2a6b668a' });
  assert.equal(METADATA_LIMIT, 8192);
});

test('recorded metadata is code identity only, never publisher or resource verification', () => {
  const value = parseBrowserSignature(GOLD, EXE);
  assert.equal(value.codeIdentityOnly, true); assert.equal(value.publisherVerified, false);
  assert.equal(value.sealedResources, false); assert.equal(value.platformCodeVerificationPerformed, false);
  assert.equal(value.cdHash, 'e52e966fc44a8c089bf511260b50fd6320e657dc');
  assert.match(value.resourcePolicy, /full-source-run-bound-manifest-required/);
  assert.deepEqual(parseBrowserSignature(GOLD.trimEnd(), EXE), value);
});
for (const line of GOLD.trimEnd().split('\n')) {
  const field = line.slice(0, line.indexOf('='));
  test('wrong recorded field refused: ' + field, () => assert.throws(() => parseBrowserSignature(GOLD.replace(line, line + 'wrong'), EXE), fails('RECORDED_CODE_IDENTITY_DIFFER')));
  test('duplicate field refused: ' + field, () => assert.throws(() => parseBrowserSignature(GOLD + line + '\n', EXE), fails('METADATA_DUPLICATE_FIELD')));
  test('missing field refused: ' + field, () => assert.throws(() => parseBrowserSignature(GOLD.replace(line + '\n', ''), EXE), fails('METADATA_INCOMPLETE')));
}
test('contradictory publisher authority is refused', () => assert.throws(() => parseBrowserSignature(GOLD + 'Authority=Developer ID Application: Someone\n', EXE), fails('PUBLISHER_AUTHORITY_CONTRADICTS_ADHOC')));
for (const char of ['\0', '\x1b', '\r', '\t', '\u0085', '\u2028']) test('control/ambiguous character refused ' + JSON.stringify(char), () => assert.throws(() => parseBrowserSignature(GOLD + char, EXE), fails('METADATA_BOUNDS_OR_CONTROL')));
for (const addition of ['\n', 'garbage\n', '=value\n', 'Authority extra=who\n', 'CDHash =other\n']) test('ambiguous/unknown metadata refused ' + JSON.stringify(addition), () => assert.throws(() => parseBrowserSignature(GOLD + addition, EXE)));
test('metadata is bounded', () => assert.throws(() => parseBrowserSignature('x'.repeat(METADATA_LIMIT + 1), EXE), fails('METADATA_BOUNDS_OR_CONTROL')));
for (const path of ['relative' + SUFFIX, '/closed/../person' + SUFFIX, EXE + '/extra', EXE + '\0', EXE.replace('1243', '9999')]) test('known path boundary ' + JSON.stringify(path), () => assert.throws(() => executableArgument(['--executable', path]), fails('KNOWN_EXECUTABLE_PATH_REQUIRED')));
test('exact arguments only', () => { assert.equal(executableArgument(['--executable', EXE]), EXE); for (const args of [[], [EXE], ['--executable', EXE, '--extra'], ['--path', EXE]]) assert.throws(() => executableArgument(args), fails('EXACT_ARGUMENTS_REQUIRED')); });
test('pinned image positive is a pure record proof; not an actual vendor read', () => assert.deepEqual(assertPinnedImage({ ...IMAGE }), IMAGE));
for (const record of [{ bytes: 52111, sha256: IMAGE.sha256 }, { bytes: 52112, sha256: '0'.repeat(64) }, { bytes: '52112', sha256: IMAGE.sha256 }, null]) test('wrong image record refused ' + JSON.stringify(record), () => assert.throws(() => assertPinnedImage(record), fails('PINNED_EXECUTABLE_BYTES_DIFFER')));
const STATS = { dev: 1n, ino: 2n, mode: 0o100755n, size: 52112n, nlink: 1n, mtimeNs: 4n, ctimeNs: 5n };
test('stable descriptor records accepted', () => assert.doesNotThrow(() => assertStableStats(STATS, { ...STATS }, { ...STATS })));
for (const key of Object.keys(STATS)) test('descriptor mutation refused ' + key, () => assert.throws(() => assertStableStats(STATS, { ...STATS, [key]: STATS[key] + 1n }), fails('EXECUTABLE_CHANGED')));
test('incomplete descriptor shape refused', () => assert.throws(() => assertStableStats(STATS, {}), fails('STABLE_STAT_SHAPE_REQUIRED')));
async function fixture(bytes = IMAGE.bytes, mode = 0o755, kind = 'file') {
  const root = await mkdtemp(join(await realpath(tmpdir()), 'rendprop-browser-signature-closed-'));
  const exe = root + SUFFIX; await mkdir(dirname(exe), { recursive: true });
  if (kind === 'directory') await mkdir(exe);
  else if (kind === 'symlink') { const target = join(root, 'closed-target'); await writeFile(target, Buffer.alloc(bytes), { mode }); await symlink(target, exe); }
  else { await writeFile(exe, Buffer.alloc(bytes), { mode }); await chmod(exe, mode); }
  return { root, exe }; // Small owned fixtures retained; no vendor cache or evidence removed.
}
test('real stable FD reads a closed wrong-hash file without changing bytes/mtime', async () => {
  const { exe } = await fixture(), before = await stat(exe, { bigint: true });
  await assert.rejects(inspectPinnedExecutable(exe), fails('PINNED_EXECUTABLE_BYTES_DIFFER'));
  const after = await stat(exe, { bigint: true }); assert.equal(before.mtimeNs, after.mtimeNs); assert.deepEqual(await readFile(exe), Buffer.alloc(IMAGE.bytes));
});
for (const [label, bytes, mode, kind] of [['short', 1, 0o755, 'file'], ['long', IMAGE.bytes + 1, 0o755, 'file'], ['writable', IMAGE.bytes, 0o777, 'file'], ['directory', 0, 0o755, 'directory'], ['symlink', IMAGE.bytes, 0o755, 'symlink']]) test('real file boundary refused ' + label, async () => { const { exe } = await fixture(bytes, mode, kind); await assert.rejects(inspectPinnedExecutable(exe), fails('EXECUTABLE_TYPE_SIZE_OR_MODE_DIFFER')); });
test('hardlinked executable refused', async () => { const { exe, root } = await fixture(); await link(exe, join(root, 'second-link')); await assert.rejects(inspectPinnedExecutable(exe), fails('EXECUTABLE_TYPE_SIZE_OR_MODE_DIFFER')); });
test('parent alias refused before reading final file', async () => {
  const root = await mkdtemp(join(await realpath(tmpdir()), 'rendprop-browser-signature-alias-')); await mkdir(join(root, 'actual-library')); await symlink(join(root, 'actual-library'), join(root, 'Library'));
  await mkdir(dirname(root + SUFFIX), { recursive: true }); await writeFile(root + SUFFIX, Buffer.alloc(IMAGE.bytes), { mode: 0o755 });
  await assert.rejects(inspectPinnedExecutable(root + SUFFIX), fails('EXECUTABLE_PARENT_ALIAS'));
});
test('bounded chunked metadata input uses no real stdin/CLI', async () => {
  async function* input() { yield Buffer.from(GOLD.slice(0, 15)); yield Buffer.from(GOLD.slice(15)); }
  assert.equal(await readMetadata(input()), GOLD);
  async function* large() { yield Buffer.alloc(METADATA_LIMIT); yield Buffer.from('x'); }
  await assert.rejects(readMetadata(large()), fails('METADATA_LIMIT'));
  async function* wrongType() { yield GOLD; } await assert.rejects(readMetadata(wrongType()), fails('STDIN_BYTES_REQUIRED'));
});
test('real closed-file open requests readonly/no-follow/nonblocking flags', async () => {
  const { exe } = await fixture(), original = fsPromises.open; let observed;
  fsPromises.open = async (path, flags, ...rest) => { observed = flags; return original(path, flags, ...rest); };
  syncBuiltinESMExports();
  try { await assert.rejects(inspectPinnedExecutable(exe), fails('PINNED_EXECUTABLE_BYTES_DIFFER')); }
  finally { fsPromises.open = original; syncBuiltinESMExports(); }
  assert.equal(observed, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
});
