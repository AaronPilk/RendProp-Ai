// Runs the actual consent class, entire PhotoEditService and PhotoWorkQueue.
// Image/network/platform boundaries are offline doubles; no camera or paid API.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const app = readFileSync(new URL('../../apps/ios/Rendprop/RendpropApp.swift', import.meta.url), 'utf8');
const begin = app.indexOf('@MainActor\nfinal class AIConsent: ObservableObject {');
const end = app.indexOf('\n/// Attach to an AI surface.', begin);
assert.ok(begin >= 0 && end > begin, 'require exact production consent boundaries');
const consent = `import Foundation\nimport Combine\n${app.slice(begin, end)}\n`;
const service = readFileSync(new URL('../../apps/ios/Rendprop/Photos/PhotoEditService.swift', import.meta.url), 'utf8')
  .replace(/^import UIKit\n/m, '').replace(/^import UserNotifications\n/m, '');
const queue = readFileSync(new URL('../../apps/ios/Rendprop/Photos/PhotoWorkQueue.swift', import.meta.url), 'utf8');
const fixture = readFileSync(new URL('PhotoConsentBatchTests.swift', import.meta.url), 'utf8');

test('actual photo batch fences revoked grants before dispatch and retains already-dispatched outputs', () => {
  const directory = mkdtempSync(join(tmpdir(), 'rendprop-photo-consent.'));
  for (const [name, contents] of [['AIConsent.swift', consent], ['PhotoWorkQueue.swift', queue],
    ['PhotoEditService.swift', service], ['Fixture.swift', fixture]]) {
    writeFileSync(join(directory, name), contents, { flag: 'wx' });
  }
  const execute = (name, serviceFile) => {
    const binary = join(directory, name);
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', join(directory, 'AIConsent.swift'),
      join(directory, 'PhotoWorkQueue.swift'), serviceFile, join(directory, 'Fixture.swift'), '-o', binary],
    { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, `${name} compile: ${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
    return spawnSync(binary, [`com.rendprop.offline-photo-consent.${randomUUID()}`],
      { encoding: 'utf8', timeout: 10000 });
  };
  const positive = execute('consent-batch', join(directory, 'PhotoEditService.swift'));
  assert.equal(positive.status, 0, `${positive.error ?? ''}\n${positive.stdout}\n${positive.stderr}`);
  assert.match(positive.stdout, /^PASS \d+ actual consent\/photo batch assertions/m);
  console.log(`Evidence: ${directory}\n${positive.stdout.trim()}`);

  // Former behavior: a running queue never checks consent at a photo boundary.
  const bypass = service.replaceAll('try requireUnsentWork()', 'try requireIdentity()')
    .replace('        guard consentIsCurrent else { return false }\n', '');
  assert.notEqual(bypass, service, 'consent bypass must change the actual service');
  writeFileSync(join(directory, 'ConsentBypass.swift'), bypass, { flag: 'wx' });
  const previous = execute('former-consent-bypass', join(directory, 'ConsentBypass.swift'));
  assert.equal(previous.status, 1, 'former queue behavior must fail a runtime assertion');
  assert.match(previous.stdout, /FAIL: Revocation after dispatch must prevent the second provider request/);
  console.log(previous.stdout.trim());

  // A boolean-only check permits revoke → regrant to revive the previous batch.
  const booleanOnly = service.replace('AIConsent.shared.isGranted && AIConsent.shared.revocationRevision == consentRevision',
    'AIConsent.shared.isGranted');
  assert.notEqual(booleanOnly, service, 'revocation revision control must alter actual service');
  writeFileSync(join(directory, 'BooleanOnly.swift'), booleanOnly, { flag: 'wx' });
  const revived = execute('revoked-grant-revival', join(directory, 'BooleanOnly.swift'));
  assert.equal(revived.status, 1, 'boolean-only consent must fail revoke/regrant runtime assertion');
  assert.match(revived.stdout, /FAIL: A later grant must not revive a batch authorized by the revoked grant/);
  console.log(revived.stdout.trim());
});
