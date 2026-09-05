// probe.test.ts — the two pure pieces of the key probe, tested with NO network.
//
//   deno test --allow-env admin/probe.test.ts
//
// Only sanitize() and the classifiers are exercised here, and that is
// deliberate: the probes themselves are HTTP calls to eleven vendors, and a
// test that mocks them would only assert that the mocks match the mocks. What
// the probes actually promise — the endpoint is $0, the status codes mean what
// the comment says — was verified against the live vendors with a bogus key on
// 2026-09-05 and is recorded in each probe's comment and in HANDOFF-P4.md.
//
// What IS testable, and is the part that would silently hurt somebody, is the
// redaction. Rule 2 of probe.ts says no credential ever leaves the module; a
// vendor error body is the one place a key can come back at us (OpenAI's 401
// quotes the key you sent). Every assertion below is that guarantee.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// probe.ts imports _shared/r2.ts, which reads its env at module load. Set the
// env BEFORE the import so nothing is evaluated against an empty environment.
// These are NOT credentials — they are placeholder strings for a module that
// never makes a call in this file.
Deno.env.set("CLOUDFLARE_ACCOUNT_ID", "probe-test-account");
Deno.env.set("R2_ACCESS_KEY_ID", "probe-test-access-key");
Deno.env.set("R2_SECRET_ACCESS_KEY", "probe-test-secret");

const {
  MAX_MESSAGE_CHARS,
  PROBES,
  classifyStatus,
  classifyThrown,
  isAbort,
  sanitize,
  thrownMessage,
} = await import("./probe.ts");

// ── sanitize(): a key must never survive ─────────────────────────────────────

// Shaped like the real things, and none of them is real.
const FAKE_OPENAI = "sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0";
const FAKE_ELEVEN = "sk_9f3c81aa04be47d2b6157c0e9a2d38fb5471ee0c";
const FAKE_FAL = "1f0a7c22-3b9e-4d51-8a6f-0c2e94b7d113:9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d";
const FAKE_ANTHROPIC = "sk-ant-api03-0Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe";

Deno.test("sanitize: a fake key never survives, in any wrapper a vendor might use", () => {
  const bodies = [
    `Incorrect API key provided: ${FAKE_OPENAI}. You can find your API key at ...`,
    `{"detail":{"message":"Invalid API key","key":"${FAKE_ELEVEN}"}}`,
    `Authorization: Key ${FAKE_FAL} was rejected`,
    `x-api-key ${FAKE_ANTHROPIC} is invalid`,
  ];
  for (const body of bodies) {
    const clean = sanitize(body);
    for (const key of [FAKE_OPENAI, FAKE_ELEVEN, FAKE_FAL, FAKE_ANTHROPIC]) {
      assert(!clean.includes(key), `whole key survived sanitize(): ${clean}`);
      // A HALF a key is still a key. Assert no long run of it survives either.
      assert(
        !clean.includes(key.slice(0, 24)),
        `a 24-char prefix of the key survived: ${clean}`,
      );
    }
    assertStringIncludes(clean, "[…]");
  }
});

Deno.test("sanitize: redacts BEFORE truncating, so a leading key cannot ride out", () => {
  // The key is at the very front, well inside the 80-char window. A
  // truncate-first implementation would return the first 79 characters of it.
  const clean = sanitize(`${FAKE_OPENAI} was rejected by the vendor`);
  assert(!clean.includes("sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2"), clean);
  assertStringIncludes(clean, "[…]");
});

Deno.test("sanitize: never longer than the cap, and collapses whitespace", () => {
  const long = "the vendor said no ".repeat(40);
  const clean = sanitize(long);
  assertEquals(clean.length <= MAX_MESSAGE_CHARS, true);
  assert(clean.endsWith("…"), clean);

  assertEquals(sanitize("  spread   over\n\n  lines  "), "spread over lines");
});

Deno.test("sanitize: leaves ordinary human words alone", () => {
  // Nothing here is 24+ characters of key alphabet, so nothing is redacted.
  const clean = sanitize("Rejected the key (HTTP 401)");
  assertEquals(clean, "Rejected the key (HTTP 401)");
  assert(!clean.includes("[…]"));
});

Deno.test("sanitize: survives a non-string (a vendor can answer with an object)", () => {
  assertEquals(sanitize(null), "");
  assertEquals(sanitize(undefined), "");
  assertEquals(sanitize(404), "404");
});

// ── classifyStatus(): 401 auth · 429 rate_limit · rest other ─────────────────

Deno.test("classifyStatus: 401 and 403 are auth", () => {
  assertEquals(classifyStatus(401), "auth");
  assertEquals(classifyStatus(403), "auth");
});

Deno.test("classifyStatus: 429 is rate_limit", () => {
  assertEquals(classifyStatus(429), "rate_limit");
});

Deno.test("classifyStatus: everything else is other", () => {
  for (const status of [400, 404, 409, 418, 500, 502, 503]) {
    assertEquals(classifyStatus(status), "other", `status ${status}`);
  }
});

// ── classifyThrown(): a throw is always reachability, never a key verdict ────

Deno.test("classifyThrown: a thrown fetch is network", () => {
  // The three shapes Deno's fetch actually throws.
  assertEquals(classifyThrown(new TypeError("error sending request for url")), "network");
  assertEquals(classifyThrown(new Error("connection closed before message completed")), "network");
  assertEquals(classifyThrown("not even an Error"), "network");
});

Deno.test("classifyThrown: our own 8-second abort is network, not auth", () => {
  const abort = new DOMException("The signal has been aborted", "AbortError");
  assertEquals(classifyThrown(abort), "network");
  assertEquals(isAbort(abort), true);
  assertStringIncludes(thrownMessage(abort), "8 seconds");
});

Deno.test("thrownMessage: a transport error is sanitized like any other text", () => {
  const message = thrownMessage(new TypeError(`sending ${FAKE_FAL} failed`));
  assert(!message.includes(FAKE_FAL), message);
  assertEquals(message.length <= MAX_MESSAGE_CHARS, true);
});

Deno.test("thrownMessage: an empty error still says something", () => {
  assertEquals(thrownMessage(new Error("")), "Could not reach the service");
});

// ── The table itself ─────────────────────────────────────────────────────────

Deno.test("PROBES: every entry is complete, unique, and documented", () => {
  const seen = new Set<string>();
  for (const probe of PROBES) {
    assert(probe.key.length > 0, "a probe has no key");
    assert(!seen.has(probe.key), `duplicate probe key: ${probe.key}`);
    seen.add(probe.key);
    assert(probe.env_names.length > 0, `${probe.key} names no env var`);
    assert(probe.how.length > 0, `${probe.key} does not say how it tests`);
    assertStringIncludes(probe.doc, "https://");
  }
  // The eleven vendors plus R2 and Stream. If this number moves, the console's
  // "Testing N keys…" copy and HANDOFF-P4.md's table both need updating.
  assertEquals(PROBES.length, 13);
});

// ── The one probe that makes no network call ─────────────────────────────────
//
// Apple has no $0 authenticated endpoint (signing in needs a real person), so
// the apple probe proves exactly one thing: the .p8 is a readable ES256 private
// key. That is a PURE claim, so it is tested for real here rather than asserted
// in a comment — and the key below is generated on the spot, so no secret is
// committed and the test cannot be made to pass by a stale fixture.

async function freshP8Pem(): Promise<string> {
    const pair = await crypto.subtle.generateKey(
        { name: "ECDSA", namedCurve: "P-256" },
        true,
        ["sign", "verify"],
    );
    const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    let binary = "";
    for (const byte of pkcs8) binary += String.fromCharCode(byte);
    const body = btoa(binary).replace(/(.{64})/g, "$1\n");
    return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
}

function setApple(p8: string): void {
  Deno.env.set("APPLE_TEAM_ID", "ABCDE12345");
  Deno.env.set("APPLE_CLIENT_ID", "com.rendprop.app");
  Deno.env.set("APPLE_KEY_ID", "PROBETEST1");
  Deno.env.set("APPLE_PRIVATE_KEY_P8", p8);
}

Deno.test("apple probe: a real ES256 .p8 parses, and says so honestly", async () => {
  const apple = PROBES.find((p) => p.key === "apple");
  assert(apple !== undefined, "the apple probe is missing");
  setApple(await freshP8Pem());

  const outcome = await apple.run(new AbortController().signal);
  assertEquals(outcome.ok, true);
  // It must NOT claim to have proved anything against Apple's servers.
  assertStringIncludes(outcome.message ?? "", "real person");
  assertStringIncludes(apple.how, "no $0 authenticated endpoint");
});

Deno.test("apple probe: the \\n-escaped shape a shell here-doc writes also parses", async () => {
  const apple = PROBES.find((p) => p.key === "apple");
  assert(apple !== undefined);
  // set-secrets.sh pipes the .p8 through a shell; this is the shape that
  // arrives when the newlines get escaped on the way. _shared/apple.ts accepts
  // it, so the probe must too — otherwise the probe reds a key that works.
  const escaped = (await freshP8Pem()).replace(/\n/g, "\\n");
  setApple(escaped);
  assertEquals((await apple.run(new AbortController().signal)).ok, true);
});

Deno.test("apple probe: a mangled .p8 fails WITHOUT quoting the key back", async () => {
  const apple = PROBES.find((p) => p.key === "apple");
  assert(apple !== undefined);
  const mangled = "-----BEGIN PRIVATE KEY-----\nbm90LWEta2V5\n-----END PRIVATE KEY-----";
  setApple(mangled);

  const outcome = await apple.run(new AbortController().signal);
  assertEquals(outcome.ok, false);
  assertEquals(outcome.error_class, "other");
  // WebCrypto's own error text can quote key bytes. Ours never does.
  assert(!(outcome.message ?? "").includes("bm90LWEta2V5"), outcome.message ?? "");
  assertStringIncludes(outcome.message ?? "", "re-paste");
});

Deno.test("PROBES: no probe names an env var that looks like a value", () => {
  // Cheap guard against somebody pasting a key where a NAME belongs. Env var
  // names are SHOUT_CASE and short; keys are long and mixed case.
  for (const probe of PROBES) {
    for (const name of probe.env_names) {
      assertEquals(name, name.toUpperCase(), `${probe.key}: "${name}" is not a NAME`);
      assert(name.length < 40, `${probe.key}: "${name}" is too long to be a NAME`);
    }
  }
});

// ── S1 adversarial review (2026-09-05) ───────────────────────────────────────

Deno.test("S1: every probe URL is a hard-coded host — no SSRF surface", () => {
  // Grep the module's own source rather than trusting a reading of it: if
  // anybody ever builds a probe URL out of an env var, a request field or a
  // config row, the host has to appear as a template hole and this fails.
  const src = Deno.readTextFileSync(new URL("./probe.ts", import.meta.url));
  const urls = [...src.matchAll(/["'`](https?:\/\/[^"'`\s]+)["'`]/g)].map((m) => m[1]);
  assert(urls.length > 10, `expected the probe table's URLs, found ${urls.length}`);
  for (const u of urls) {
    // A `${` before the first single slash after the scheme would be a
    // caller-controlled HOST. Interpolation later in the PATH is fine — the two
    // that use it (Cloudflare account id, GHL location id) are env-derived and
    // encodeURIComponent'd.
    const afterScheme = u.slice(u.indexOf("//") + 2);
    const host = afterScheme.split("/")[0];
    assert(!host.includes("${"), `interpolated host: ${u}`);
    assert(/^[a-z0-9.-]+$/i.test(host), `not a literal host: ${host}`);
  }
});

Deno.test("S1: probes never follow a redirect (a vendor 302 must not carry the key)", () => {
  // Only `Authorization` is stripped when fetch follows a cross-origin
  // redirect. Every probe here carries its credential in a VENDOR header —
  // x-api-key, xi-api-key, x-goog-api-key, Api-Key — so following a redirect
  // to a hijacked host would hand it over. `redirect: "manual"` turns that into
  // a visible "Unexpected answer (HTTP 30x)" instead.
  const src = Deno.readTextFileSync(new URL("./probe.ts", import.meta.url));
  assert(src.includes('redirect: "manual"'), "getJson must not follow redirects");
  assert(!src.includes('redirect: "follow"'), "no probe may follow redirects");
  // 3xx is not a pass: classifyStatus only calls 401/403 auth and 429 rate
  // limit, and the ok flag comes from an explicit 2xx test in each probe.
  assertEquals(classifyStatus(302), "other");
  assertEquals(classifyStatus(307), "other");
});

Deno.test("S1: sanitize survives the shapes a key is usually pasted in", () => {
  // Long unbroken runs are the common case and are covered above. These are the
  // ones with separators, where the redactor has to catch each RUN.
  const jwtish = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  const out = sanitize(`upstream said: ${jwtish}`);
  for (const part of jwtish.split(".")) {
    if (part.length >= 24) assert(!out.includes(part), `leaked a JWT segment: ${part}`);
  }
  const bearer = "Bearer sk-proj-AbCdEf0123456789AbCdEf0123456789AbCdEf01";
  assert(!sanitize(`401: ${bearer}`).includes("AbCdEf0123456789"));
});
