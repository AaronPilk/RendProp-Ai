import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

test('required account launch preserves legacy adoption and fences deferred routes', () => {
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const result = spawnSync('python3', ['tools/audit/required-account-onboarding-20261008/run.py'], {
    cwd: root, encoding: 'utf8', timeout: 1_300_000,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Evidence:/);
  console.log(result.stdout.trim());
});
