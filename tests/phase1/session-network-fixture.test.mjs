import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('session UI fixture retries an identified refresh, never guest signup', async () => {
  const probe = createServer();
  await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const out = await mkdtemp(join(tmpdir(), 'rendprop-session-fixture-'));
  const media = join(out, 'clip.mp4');
  await writeFile(media, 'closed media, not an encoding test');
  const child = spawn(process.execPath, [fileURLToPath(new URL('./fixture-server.mjs', import.meta.url)), String(port), media],
    { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Fixture server did not start: ' + stderr)), 5000);
      child.stdout.on('data', chunk => {
        if (String(chunk).includes('Local fixture ready')) { clearTimeout(timer); resolve(); }
      });
      child.on('error', reject);
      child.on('exit', code => { clearTimeout(timer); reject(new Error('Fixture server exited: ' + code + ' ' + stderr)); });
    });
    const base = `http://127.0.0.1:${port}`;
    const post = (route, body, token) => fetch(base + route, { method: 'POST', headers: {
      'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {})
    }, body: JSON.stringify(body) });
    const payload = jwt => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url'));
    await fetch(base + '/__control/reset');
    const signIn = await post('/auth/v1/token?grant_type=id_token', {
      provider: 'apple', id_token: 'rendprop-session-network-identified-fixture'
    });
    assert.equal(signIn.status, 200);
    const initial = await signIn.json();
    assert.equal(payload(initial.access_token).is_anonymous, false);
    assert.equal(payload(initial.access_token).sub, '10000000-0000-4000-8000-000000000003');
    assert.equal(initial.expires_in, 30);
    assert.ok(payload(initial.access_token).exp > Date.now()/1000);
    assert.ok(payload(initial.access_token).exp <= Date.now()/1000 + 60, 'real ensureSession refresh threshold');
    await assert.rejects(post('/auth/v1/token?grant_type=refresh_token', { refresh_token: initial.refresh_token }),
      /fetch failed/, 'blocked refresh loses the real TCP connection');
    let state = await (await fetch(base + '/__control/state')).json();
    assert.equal(state.identifiedExchanges, 1);
    assert.equal(state.accepted, 0);
    assert.equal(state.requests['/auth/v1/token?grant_type=refresh_token'], 1);
    assert.equal(state.requests['/auth/v1/signup'] ?? 0, 0);
    assert.equal(state.requests['/functions/v1/ai-photo'] ?? 0, 0);
    await fetch(base + '/__control/unblock');
    const refreshed = await (await post('/auth/v1/token?grant_type=refresh_token', { refresh_token: initial.refresh_token })).json();
    assert.equal(payload(refreshed.access_token).is_anonymous, false);
    assert.equal(payload(refreshed.access_token).sub, payload(initial.access_token).sub);
    assert.equal(refreshed.expires_in, 3600);
    assert.equal((await post('/functions/v1/ai-photo', { image_b64: 'selected-photo' }, initial.access_token)).status, 401);
    const edit = await post('/functions/v1/ai-photo', { image_b64: 'selected-photo' }, refreshed.access_token);
    assert.equal(edit.status, 200);
    assert.equal((await edit.json()).image_b64, 'selected-photo');
    state = await (await fetch(base + '/__control/state')).json();
    assert.equal(state.accepted, 1);
    assert.equal(state.identifiedExchanges, 1);
    assert.equal(state.requests['/auth/v1/signup'] ?? 0, 0);
    assert.equal((await post('/auth/v1/signup', {})).status, 403, 'obsolete guest flow fails explicitly');
    await fetch(base + '/__control/reset');
    state = await (await fetch(base + '/__control/state')).json();
    assert.equal(state.accepted, 0); assert.equal(state.identifiedExchanges, 0);
    assert.deepEqual(state.requests, {});

    const fixture = await readFile(new URL('../../apps/ios/Rendprop/Auth/PhaseOneFixtures.swift', import.meta.url), 'utf8');
    assert.ok(fixture.startsWith('#if DEBUG && targetEnvironment(simulator)'));
    assert.ok(fixture.includes('exchangeAppleIdentityToken('));
    assert.ok(!fixture.includes('signInAnonymouslyIfNeeded('));
  } finally {
    child.kill('SIGTERM');
    await rm(out, { recursive: true, force: true });
  }
});
