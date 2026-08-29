// Sign in with Apple server-side token handling (TN3194).
//
// Flow: the app sends the sign-in `authorizationCode` to POST /me/apple-code;
// we exchange it (codes are single-use and expire in ~5 minutes) for a refresh
// token stored on the profile. DELETE /me revokes that refresh token so the
// user's Apple grant is severed — Apple requires this for account deletion.
//
// Env (all four required to activate):
//   APPLE_TEAM_ID         e.g. ABCDE12345
//   APPLE_CLIENT_ID       the app's bundle id (com.rendprop.app)
//   APPLE_KEY_ID          the Sign in with Apple key id
//   APPLE_PRIVATE_KEY_P8  the .p8 contents (PEM, newlines or \n-escaped)

const TEAM_ID = Deno.env.get("APPLE_TEAM_ID");
const CLIENT_ID = Deno.env.get("APPLE_CLIENT_ID");
const KEY_ID = Deno.env.get("APPLE_KEY_ID");
const PRIVATE_KEY_P8 = Deno.env.get("APPLE_PRIVATE_KEY_P8");

export function appleConfigured(): boolean {
  return Boolean(TEAM_ID && CLIENT_ID && KEY_ID && PRIVATE_KEY_P8);
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buf = new ArrayBuffer(raw.length);
  const out = new Uint8Array(buf);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return buf;
}

/** ES256-signed client secret JWT (valid 15 minutes). */
async function clientSecret(): Promise<string> {
  if (!appleConfigured()) throw new Error("Apple revocation not configured");
  const now = Math.floor(Date.now() / 1000);
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: KEY_ID })));
  const payload = b64url(enc.encode(JSON.stringify({
    iss: TEAM_ID,
    iat: now,
    exp: now + 900,
    aud: "https://appleid.apple.com",
    sub: CLIENT_ID,
  })));
  const signingInput = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(PRIVATE_KEY_P8!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    enc.encode(signingInput),
  ));
  return `${signingInput}.${b64url(sig)}`;
}

/** Exchange the app's authorizationCode → Apple refresh token. */
export async function exchangeAppleCode(code: string): Promise<string | null> {
  const secret = await clientSecret();
  const form = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: CLIENT_ID!,
    client_secret: secret,
  });
  const res = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(`Apple token exchange failed (${res.status}): ${JSON.stringify(data)?.slice(0, 200)}`);
  }
  return (data?.refresh_token as string | undefined) ?? null;
}

/** Revoke a stored Apple refresh token. True when Apple accepted it. */
export async function revokeAppleToken(refreshToken: string): Promise<boolean> {
  const secret = await clientSecret();
  const form = new URLSearchParams({
    client_id: CLIENT_ID!,
    client_secret: secret,
    token: refreshToken,
    token_type_hint: "refresh_token",
  });
  const res = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  return res.ok;
}
