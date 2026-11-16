import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../../', import.meta.url));
const formatterPath = root + 'apps/ios/Rendprop/Support/Formatters.swift';
const reviewPath = root + 'apps/ios/Rendprop/Screens/ReviewSubmitView.swift';
const formatter = readFileSync(formatterPath, 'utf8');
const review = readFileSync(reviewPath, 'utf8');
const expectedSwiftTrapSignal = { arm64: 'SIGTRAP', x64: 'SIGILL' }[process.arch];

function declaration(source, needle) {
  assert.equal(source.split(needle).length - 1, 1, `unique actual declaration ${needle}`);
  const begin = source.lastIndexOf('\n', source.indexOf(needle)) + 1;
  let position = source.indexOf('{', source.indexOf(needle)), depth = 1;
  while (depth > 0 && ++position < source.length) {
    if (source[position] === '{') depth++;
    if (source[position] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(begin, position + 1);
}

test('actual Formatters and ReviewSubmitView metadata reject invalid values without Swift numeric traps', () => {
  assert.ok(expectedSwiftTrapSignal, `Unsupported Swift trap architecture: ${process.arch}`);
  const out = mkdtempSync(join(tmpdir(), 'rendprop-formatters-swift-'));
  const summaryLines = review.split('\n').filter(line => line.includes('Text("\\(Formatters.duration(asset.durationS))'));
  assert.equal(summaryLines.length, 1, 'actual capture summary registered exactly once');
  const summary = summaryLines[0].trim().slice('Text('.length, -1);
  const timeLabel = declaration(review, 'private func timeLabel(');
  const scaffold = `import Foundation\n// Inert business-preference dependency; no host preferences are read.\nstruct SpaceType { static let current = SpaceType(); var quickTags:[String] { [] } }\nstruct ActualReviewMetadata {\n${timeLabel}\nfunc time(_ s:Double)->String { timeLabel(s) }\nfunc summary(_ asset:CaptureAsset)->String { ${summary} }\n}\n`;
  const generated = join(out, 'ActualReviewMetadata.swift');
  writeFileSync(generated, scaffold, { flag: 'wx' });
  const files = ['CaptureAsset', 'RoomTag'].map(name => root + `apps/ios/Rendprop/Models/${name}.swift`);
  const harness = root + 'tests/phase1/FormattersRuntimeTests.swift';
  const run = (name, formatPath, reviewSource, args = []) => {
    const metadataPath = join(out, name + '-metadata.swift');
    writeFileSync(metadataPath, reviewSource, { flag: 'wx' });
    const binary = join(out, name);
    const compiled = spawnSync('/usr/bin/swiftc', ['-parse-as-library', ...files, formatPath, metadataPath, harness, '-o', binary],
      { encoding: 'utf8', timeout: 60_000 });
    writeFileSync(join(out, name + '-compile.log'), compiled.stdout + compiled.stderr, { flag: 'wx' });
    assert.equal(compiled.status, 0, compiled.stderr);
    const result = spawnSync(binary, args, { encoding: 'utf8', timeout: 30_000 });
    writeFileSync(join(out, name + '-run.log'), result.stdout + result.stderr, { flag: 'wx' });
    return { binary, result };
  };
  const actual = run('actual', formatterPath, scaffold);
  assert.equal(actual.result.status, 0, actual.result.stdout + actual.result.stderr);
  assert.match(actual.result.stdout, /PASS: \d+ actual formatter and ReviewSubmitView metadata assertions/);
  const negative = spawnSync(actual.binary, ['--force-failure'], { encoding: 'utf8', timeout: 30_000 });
  assert.equal(negative.status, 1);
  assert.match(negative.stdout, /deliberate negative control/);

  const safeConversion = 'return Int(exactly: value.rounded())';
  assert.equal(formatter.split(safeConversion).length - 1, 1);
  const unsafeFormat = join(out, 'UnsafeFormatters.swift');
  // Reintroduces only the original out-of-range integer conversion. A giant
  // finite duration must still kill the mutant after it passes normal values.
  writeFileSync(unsafeFormat, formatter.replace(safeConversion, 'return Int(value.rounded())'), { flag: 'wx' });
  const formatMutant = run('unchecked-conversion', unsafeFormat, scaffold).result;
  assert.equal(formatMutant.signal, expectedSwiftTrapSignal, 'unsafe production conversion mutant must reproduce a Swift trap');
  assert.match(formatMutant.stderr, /Double value cannot be converted to Int/);

  const safeFPS = 'Formatters.frameRate(asset.fps)';
  assert.equal(scaffold.split(safeFPS).length - 1, 1);
  const fpsMutant = run('unchecked-review-fps', formatterPath,
    scaffold.replace(safeFPS, 'String(Int(asset.fps.rounded())) + " fps"'), ['--fps-only']).result;
  assert.equal(fpsMutant.signal, expectedSwiftTrapSignal, 'original unchecked actual summary FPS mutant must trap');
  assert.match(fpsMutant.stderr, /Double value cannot be converted to Int/);
  console.log(`Formatter evidence: ${out}\n${actual.result.stdout.trim()}\nPASS: both original numeric conversion mutants reproduced ${expectedSwiftTrapSignal}`);
  const checked = [formatterPath, reviewPath, ...files, harness, fileURLToPath(import.meta.url)];
  writeFileSync(join(out, 'receipt.json'), JSON.stringify({ accepted: true,
    scope: 'Complete production Formatters/CaptureAsset/RoomTag plus mechanically extracted, unchanged ReviewSubmitView timeLabel and summary expression. No SwiftUI/camera/network/provider/Apple execution.',
    actualExit: actual.result.status, negativeControlExit: negative.status,
    mutantSignals: [formatMutant.signal, fpsMutant.signal],
    sourceHashes: Object.fromEntries(checked.map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
    extractedSourceSHA256: createHash('sha256').update(scaffold).digest('hex'),
  }, null, 2) + '\n', { flag: 'wx' });
});
