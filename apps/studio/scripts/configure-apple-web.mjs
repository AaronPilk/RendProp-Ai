// Configure/renew Rendprop's Apple web OAuth without printing any credential.
// The Services ID and signing key must already be linked to com.rendprop.app
// in Apple's Developer portal. This changes only this project's Apple OAuth
// fields and appends Studio's exact callback to existing allowed redirects.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  'key-file': { type: 'string' },
  'key-id': { type: 'string' },
  'token-file': { type: 'string' },
  apply: { type: 'boolean', default: false },
} });
assert(values['key-file'] && values['token-file'], 'Provide key-file and token-file paths. Never pass credential values.');
assert(/^[A-Z0-9]{10}$/.test(values['key-id'] ?? ''), 'A valid Apple Sign in key ID is required.');
const project = 'ymgqpbnjpztwjsyvceld';
const team = '5F5C5G25Y6';
const nativeId = 'com.rendprop.app';
const serviceId = 'com.rendprop.studio';
const redirect = 'https://studio.rendprop.com/';
const managementUrl = `https://api.supabase.com/v1/projects/${project}/config/auth`;
const token = (await readFile(values['token-file'], 'utf8')).trim();
assert(token.length > 20, 'Management credential is missing.');
const privateKey = createPrivateKey(await readFile(values['key-file'], 'utf8'));
assert(privateKey.asymmetricKeyType === 'ec' && privateKey.asymmetricKeyDetails?.namedCurve === 'prime256v1', 'Apple key must use P-256.');
const now = Math.floor(Date.now() / 1000);
const expires = now + 180 * 24 * 60 * 60;
const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const signingInput = `${encode({ alg: 'ES256', kid: values['key-id'] })}.${encode({ iss: team, iat: now, exp: expires, aud: 'https://appleid.apple.com', sub: serviceId })}`;
const signature = sign('sha256', Buffer.from(signingInput), { key: privateKey, dsaEncoding: 'ieee-p1363' });
assert(verify('sha256', Buffer.from(signingInput), { key: createPublicKey(privateKey), dsaEncoding: 'ieee-p1363' }, signature), 'Client secret signature check failed.');
const clientSecret = `${signingInput}.${signature.toString('base64url')}`;
async function configRequest(method, body) {
  let response;
  try {
    response = await fetch(managementUrl, {
      method,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      redirect: 'error', signal: AbortSignal.timeout(20000),
    });
  } catch { throw new Error(`Auth configuration ${method} could not reach Supabase.`); }
  // Do not include arbitrary response bodies: they can contain credentials.
  assert(response.ok, `Auth configuration ${method} failed (${response.status}).`);
  try { return await response.json(); }
  catch { throw new Error(`Auth configuration ${method} returned an unreadable response.`); }
}
const split = (value) => String(value ?? '').split(',').map(s => s.trim()).filter(Boolean);
const before = await configRequest('GET');
const existingIds = split(before.external_apple_client_id);
assert(existingIds.includes(nativeId), 'Refusing to change a project without Rendprop native Apple auth.');
assert(before.external_apple_enabled === true, 'Existing native Apple auth must be enabled.');
const ids = [serviceId, ...existingIds.filter(id => id !== serviceId)];
const redirects = [...new Set([...split(before.uri_allow_list), redirect])];
if (values.apply) {
  await configRequest('PATCH', {
    external_apple_enabled: true,
    external_apple_client_id: ids.join(','),
    external_apple_secret: clientSecret,
    uri_allow_list: redirects.join(','),
  });
  const after = await configRequest('GET');
  assert.deepEqual(split(after.external_apple_client_id), ids, 'Apple client IDs read-back mismatch.');
  assert.deepEqual(split(after.uri_allow_list), redirects, 'Redirect read-back mismatch.');
  for (const field of ['site_url', 'external_anonymous_users_enabled', 'external_apple_additional_client_ids', 'external_email_enabled', 'disable_signup', 'external_apple_email_optional'])
    assert.deepEqual(after[field], before[field], `Unrelated auth setting changed: ${field}`);
  assert(after.external_apple_enabled === true, 'Apple provider must remain enabled.');
}
console.log(JSON.stringify({
  project, applied: values.apply, servicesId: serviceId, nativeId,
  nativeAudiencePreserved: true, existingRedirectsPreserved: true,
  studioRedirect: redirect, keyId: values['key-id'],
  secretExpiresAt: new Date(expires * 1000).toISOString(),
  renewBefore: new Date((expires - 14 * 24 * 60 * 60) * 1000).toISOString(),
  readAt: new Date().toISOString(),
}, null, 2));
