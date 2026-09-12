import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
const auth = readFileSync(new URL('../../apps/ios/Rendprop/Auth/AuthStore.swift', import.meta.url), 'utf8');
const settings = readFileSync(new URL('../../apps/ios/Rendprop/Screens/SettingsView.swift', import.meta.url), 'utf8');
test('AuthStore durably prepares source before identified session replacement', () => {
  const exchange = auth.slice(auth.indexOf('func exchangeAppleIdentityToken'), auth.indexOf('// MARK: - Anonymous sessions'));
  assert.ok(exchange.indexOf('recovery.prepare(') >= 0);
  assert.ok(exchange.indexOf('recovery.prepare(') < exchange.indexOf('applySession('));
  assert.ok(exchange.includes('sourceRefresh: priorRefresh'));
  assert.ok(exchange.includes('try SecureStore.getChecked(Keys.accessToken)'));
  assert.ok(exchange.includes('try SecureStore.getChecked(Keys.refreshToken)'));
  assert.ok(exchange.includes('throw APIError.server'));
});
test('Settings exposes labeled non-secret recovery and support, without gating features', () => {
  const section = settings.slice(settings.indexOf('if let message = auth.adoptionRecoveryMessage'), settings.indexOf('if Config.useLiveBackend {\n                usageSection'));
  assert.ok(section.includes('Text(message)'));
  assert.ok(section.includes('Label("Retry workspace transfer"'));
  assert.ok(section.includes('await auth.retryPendingAdoptionIfNeeded()'));
  assert.ok(section.includes('Label("Get recovery help"'));
  assert.ok(!section.includes('token') && !section.includes('userID'));
});
test('launch and foreground retry the durable handoff; sign-out discards it through the recovery object', () => {
  const init = auth.slice(auth.indexOf('    init()'), auth.indexOf('// MARK: - Token access'));
  assert.equal(init.split('retryPendingAdoptionIfNeeded()').length - 1, 2);
  // A signed-out phone has no anonymous source left to hand off; keeping the
  // record made the next Apple sign-in 409 forever. Sign-out must drop it, and
  // only the recovery object may touch the Keychain record (no inline deletes).
  const signOut = auth.slice(auth.indexOf('func signOut()'), auth.indexOf('func setDisplayName'));
  assert.ok(signOut.includes('discardPendingAdoption()'));
  assert.ok(!signOut.includes('Keys.pendingAdoption'));
});
test('pending Keychain read fails closed and callbacks retain session generation fence', () => {
  assert.ok(auth.includes('try SecureStore.getChecked(Keys.pendingAdoption)'));
  assert.ok(auth.includes('self?.sessionEpoch == epoch'));
  assert.ok(auth.includes('adoptionRecoveryMessage'));
  assert.ok(!auth.includes('adoptAnonymousWork(anonymousToken:'));
});
