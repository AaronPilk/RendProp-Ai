// Compile copied ACTUAL production source with individual broken guards. These
// are executable regression controls, not a second recovery implementation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = fileURLToPath(new URL('../../', import.meta.url));
const source = readFileSync(join(root, 'apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift'), 'utf8');
const harness = join(root, 'tests/phase1/AnonymousAdoptionRecoveryTests.swift');
const out = mkdtempSync(join(tmpdir(), 'rendprop-adoption-mutants-'));
for (const [name, needle, broken] of [
  ['source-destination-binding', 'destination.id == value.destinationUserID, isCurrent()', 'true, isCurrent()'],
  ['receipt-operation-binding', 'receipt.adopted, receipt.operation_id == value.operationID,', 'receipt.adopted, true,'],
  ['write-failure-before-replacement', 'write(raw) else', '(write(raw) || true) else'],
  ['late-response-fence', 'guard !Task.isCancelled, isCurrent() else { return }\n                if (200..<300)', 'if (200..<300)'],
]) {
  test(`real recovery mutant rejected: ${name}`, { timeout: 30000 }, () => {
    assert.equal(source.split(needle).length - 1, 1, 'unique actual-source mutation');
    const path = join(out, `${name}.swift`), binary = join(out, name);
    writeFileSync(path, source.replace(needle, broken));
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', path, harness, '-o', binary], {
      cwd: resolve(root), encoding: 'utf8', timeout: 20000,
    });
    writeFileSync(join(out, `${name}-compile.log`), compile.stdout + compile.stderr);
    assert.equal(compile.status, 0, 'mutant must compile; syntax failure is not a rejected behavioral mutant');
    const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 5000 });
    writeFileSync(join(out, `${name}-run.log`), run.stdout + run.stderr);
    assert.equal(run.status, 1, 'actual production-helper mutation must fail executable assertions');
    assert.match(run.stdout, /FAIL: [1-9]\d* \/ \d+ assertions/);
  });
}
console.log(`Adoption copied-source controls: ${out}`);
