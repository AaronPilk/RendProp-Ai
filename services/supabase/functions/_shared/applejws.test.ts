// applejws.test.ts — the certificate-chain verifier, exercised end to end
// against a chain this file mints at test time.
//
//   deno test --allow-env _shared/applejws.test.ts
//
// No network, no fixtures, no committed private keys. Apple will not hand out a
// signing key, so the only honest way to test "a valid chain passes and every
// broken one fails" is to BUILD a three-certificate chain here with WebCrypto
// and a DER writer, then inject its root through the `trustRoot` test hook (see
// VerifyAppleJWSOptions.trustRoot — it is unreachable from a request, and this
// file is the only caller that ever passes it).
//
// What that buys: every check in verifyAppleJWS runs for real. The DER parser
// walks certificates it did not write the parser for; ECDSA verification is
// WebCrypto's, not a stub; and each negative test breaks exactly ONE thing, so
// a failure names the check that regressed.
//
// The one thing a synthetic chain cannot prove is that the embedded Apple Root
// CA - G3 bytes are the right bytes — so that is asserted directly, by hashing
// them and comparing to the fingerprint Apple publishes.

import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import {
  APPLE_ROOT_CA_G3_DER,
  type AppleRenewalInfo,
  type AppleTransaction,
  decodeRenewalInfo,
  decodeTransaction,
  deriveEntitlement,
  productToPlan,
  verifyAppleJWS,
} from "./applejws.ts";

// ── A DER writer (test-only) ────────────────────────────────────────────────
//
// Just enough of X.690 to emit an X.509 v3 certificate: definite lengths, one
// TLV helper, and the handful of universal types a certificate needs.

type Bytes = Uint8Array<ArrayBuffer>;

function concat(parts: Uint8Array[]): Bytes {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** tag + definite length + content. */
function tlv(tag: number, content: Uint8Array): Bytes {
  const len = content.length;
  let header: number[];
  if (len < 0x80) {
    header = [tag, len];
  } else {
    const lenBytes: number[] = [];
    let n = len;
    while (n > 0) {
      lenBytes.unshift(n & 0xff);
      n = Math.floor(n / 256);
    }
    header = [tag, 0x80 | lenBytes.length, ...lenBytes];
  }
  return concat([new Uint8Array(header), content]);
}

const seq = (...parts: Uint8Array[]) => tlv(0x30, concat(parts));
const set = (...parts: Uint8Array[]) => tlv(0x31, concat(parts));
const octet = (b: Uint8Array) => tlv(0x04, b);
const bool = (v: boolean) => tlv(0x01, new Uint8Array([v ? 0xff : 0x00]));
const derNull = () => new Uint8Array([0x05, 0x00]);
const explicit = (n: number, content: Uint8Array) => tlv(0xa0 | n, content);

/** BIT STRING with zero unused bits. */
const bitString = (b: Uint8Array) => tlv(0x03, concat([new Uint8Array([0x00]), b]));

/** DER INTEGER from an unsigned big-endian magnitude. */
function integer(magnitude: Uint8Array): Bytes {
  let s = 0;
  while (s < magnitude.length - 1 && magnitude[s] === 0) s++;
  let body = magnitude.subarray(s);
  if (body.length === 0) body = new Uint8Array([0]);
  if (body[0] & 0x80) body = concat([new Uint8Array([0]), body]);
  return tlv(0x02, body);
}

const smallInt = (n: number) => integer(new Uint8Array([n]));

function oid(dotted: string): Bytes {
  const arcs = dotted.split(".").map(Number);
  const body: number[] = [arcs[0] * 40 + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const chunk: number[] = [arc & 0x7f];
    let v = Math.floor(arc / 128);
    while (v > 0) {
      chunk.unshift((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    body.push(...chunk);
  }
  return tlv(0x06, new Uint8Array(body));
}

/** UTCTime, YYMMDDHHMMSSZ. */
function utcTime(d: Date): Bytes {
  const p = (n: number) => String(n).padStart(2, "0");
  const s = `${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  return tlv(0x17, new TextEncoder().encode(s));
}

/** RDNSequence with a single CN. */
function name(cn: string): Bytes {
  return seq(set(seq(oid("2.5.4.3"), tlv(0x0c, new TextEncoder().encode(cn)))));
}

const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_LEAF_MARKER = "1.2.840.113635.100.6.11.1";
const OID_INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";

function extension(id: string, critical: boolean, value: Uint8Array): Bytes {
  return critical
    ? seq(oid(id), bool(true), octet(value))
    : seq(oid(id), octet(value));
}

const caExtension = () => extension(OID_BASIC_CONSTRAINTS, true, seq(bool(true)));
const markerExtension = (id: string) => extension(id, false, derNull());

/** raw r‖s (WebCrypto) → DER SEQUENCE { INTEGER r, INTEGER s } (X.509). */
function rawSigToDer(raw: Uint8Array): Bytes {
  const half = raw.length / 2;
  return seq(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
}

interface KeyPairEc {
  publicKey: CryptoKey;
  privateKey: CryptoKey;
  spki: Bytes;
}

async function generateKey(): Promise<KeyPairEc> {
  const kp = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey));
  return { publicKey: kp.publicKey, privateKey: kp.privateKey, spki };
}

interface CertSpec {
  subject: string;
  issuer: string;
  subjectKey: KeyPairEc;
  issuerKey: KeyPairEc;
  serial: number;
  notBefore: Date;
  notAfter: Date;
  extensions: Uint8Array[];
}

async function makeCert(spec: CertSpec): Promise<Bytes> {
  const algId = seq(oid(OID_ECDSA_SHA256));
  const tbs = seq(
    explicit(0, smallInt(2)), // v3
    smallInt(spec.serial),
    algId,
    name(spec.issuer),
    seq(utcTime(spec.notBefore), utcTime(spec.notAfter)),
    name(spec.subject),
    spec.subjectKey.spki,
    explicit(3, seq(...spec.extensions)),
  );
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, spec.issuerKey.privateKey, tbs),
  );
  return seq(tbs, algId, bitString(rawSigToDer(raw)));
}

// ── base64 helpers ──────────────────────────────────────────────────────────

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** base64url -> bytes, so a test can flip a real bit rather than a padding one. */
function decodeB64Url(s: string): Bytes {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ── The chain factory ───────────────────────────────────────────────────────

const HOUR = 3600_000;
const YEAR = 365 * 24 * HOUR;

interface Chain {
  rootDer: Bytes;
  intermediateDer: Bytes;
  leafDer: Bytes;
  leafKey: KeyPairEc;
}

interface ChainOptions {
  now?: Date;
  /** Leave the leaf's App Store marker OID off. */
  omitLeafMarker?: boolean;
  /** Leave the intermediate's WWDR marker OID off. */
  omitIntermediateMarker?: boolean;
  /** Emit the intermediate without basicConstraints cA=TRUE. */
  intermediateNotCa?: boolean;
  /** Expire the leaf (notAfter one hour in the past). */
  expiredLeaf?: boolean;
}

async function buildChain(o: ChainOptions = {}): Promise<Chain> {
  const now = o.now ?? new Date();
  const from = new Date(now.getTime() - YEAR);
  const to = new Date(now.getTime() + YEAR);

  const rootKey = await generateKey();
  const intermediateKey = await generateKey();
  const leafKey = await generateKey();

  const rootDer = await makeCert({
    subject: "Test Root CA",
    issuer: "Test Root CA",
    subjectKey: rootKey,
    issuerKey: rootKey,
    serial: 1,
    notBefore: from,
    notAfter: to,
    extensions: [caExtension()],
  });

  const intermediateDer = await makeCert({
    subject: "Test Intermediate CA",
    issuer: "Test Root CA",
    subjectKey: intermediateKey,
    issuerKey: rootKey,
    serial: 2,
    notBefore: from,
    notAfter: to,
    extensions: [
      ...(o.intermediateNotCa ? [] : [caExtension()]),
      ...(o.omitIntermediateMarker ? [] : [markerExtension(OID_INTERMEDIATE_MARKER)]),
    ],
  });

  const leafDer = await makeCert({
    subject: "Test Leaf",
    issuer: "Test Intermediate CA",
    subjectKey: leafKey,
    issuerKey: intermediateKey,
    serial: 3,
    notBefore: from,
    notAfter: o.expiredLeaf ? new Date(now.getTime() - HOUR) : to,
    extensions: [...(o.omitLeafMarker ? [] : [markerExtension(OID_LEAF_MARKER)])],
  });

  return { rootDer, intermediateDer, leafDer, leafKey };
}

async function signJws(
  chain: Chain,
  payload: unknown,
  header: Record<string, unknown> = {},
): Promise<string> {
  const enc = new TextEncoder();
  const h = b64url(enc.encode(JSON.stringify({
    alg: "ES256",
    x5c: [b64(chain.leafDer), b64(chain.intermediateDer), b64(chain.rootDer)],
    ...header,
  })));
  const p = b64url(enc.encode(JSON.stringify(payload)));
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      chain.leafKey.privateKey,
      enc.encode(`${h}.${p}`),
    ),
  );
  return `${h}.${p}.${b64url(sig)}`;
}

const BUNDLE_ID = "com.rendprop.app";

function transactionPayload(over: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Date.now();
  return {
    transactionId: "2000000700000001",
    originalTransactionId: "2000000700000000",
    webOrderLineItemId: "2000000050000000",
    bundleId: BUNDLE_ID,
    productId: "com.rendprop.app.pro.monthly",
    subscriptionGroupIdentifier: "rendprop_plans",
    purchaseDate: now,
    originalPurchaseDate: now,
    expiresDate: now + 30 * 24 * HOUR,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    signedDate: now,
    environment: "Sandbox",
    transactionReason: "PURCHASE",
    storefront: "USA",
    currency: "USD",
    price: 9900,
    ...over,
  };
}

/** 401 with the "unauthorized" code — what every verification failure must be. */
async function expectUnauthorized(fn: () => Promise<unknown>, expectMessage?: string) {
  const err = await assertRejects(fn, HttpError);
  assertEquals(err.status, 401);
  assertEquals(err.code, "unauthorized");
  if (expectMessage) assertStringIncludes(err.message, expectMessage);
  return err;
}

// ── The pinned root is the root Apple publishes ─────────────────────────────

Deno.test("the embedded Apple Root CA - G3 matches Apple's published SHA-256", async () => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", APPLE_ROOT_CA_G3_DER));
  const hex = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  // https://www.apple.com/certificateauthority/AppleRootCA-G3.cer, fetched 2026-09-05.
  assertEquals(hex, "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179");
  assertEquals(APPLE_ROOT_CA_G3_DER.length, 583);
});

// ── The happy path ──────────────────────────────────────────────────────────

Deno.test("a valid chain verifies and the payload decodes", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());

  const payload = await verifyAppleJWS(jws, { trustRoot: chain.rootDer });
  const tx = decodeTransaction(payload);

  assertEquals(tx.bundleId, BUNDLE_ID);
  assertEquals(tx.productId, "com.rendprop.app.pro.monthly");
  assertEquals(tx.originalTransactionId, "2000000700000000");
  assertEquals(tx.inAppOwnershipType, "PURCHASED");
  assertEquals(tx.environment, "Sandbox");
  assertEquals(tx.revocationDate, null);
  assert(tx.expiresDate !== null, "expiresDate must decode");
  assert(Date.parse(tx.expiresDate!) > Date.now(), "expiresDate must be in the future");
  assertEquals(productToPlan(tx.productId), "pro");
});

Deno.test("renewal info decodes, including the grace-period window", async () => {
  const chain = await buildChain();
  const graceUntil = Date.now() + 16 * 24 * HOUR;
  const jws = await signJws(chain, {
    originalTransactionId: "2000000700000000",
    autoRenewProductId: "com.rendprop.app.pro.monthly",
    productId: "com.rendprop.app.pro.monthly",
    autoRenewStatus: 1,
    renewalDate: Date.now() + 30 * 24 * HOUR,
    gracePeriodExpiresDate: graceUntil,
    isInBillingRetryPeriod: true,
    expirationIntent: 1,
    environment: "Sandbox",
    signedDate: Date.now(),
  });

  const info = decodeRenewalInfo(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(info.autoRenewStatus, 1);
  assertEquals(info.isInBillingRetryPeriod, true);
  assertEquals(info.gracePeriodExpiresDate, new Date(graceUntil).toISOString());
  assertEquals(info.expirationIntent, 1);
});

// ── The chain must end at the pinned root ───────────────────────────────────

Deno.test("a chain rooted anywhere else is rejected", async () => {
  const chain = await buildChain();
  const other = await buildChain(); // a different, equally well-formed root
  const jws = await signJws(chain, transactionPayload());

  // Told to trust a DIFFERENT root: the presented root is not it.
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: other.rootDer }),
    "pinned Apple root",
  );

  // And with no override at all, the expected root is Apple's real one, so a
  // test chain can never pass through the production code path.
  await expectUnauthorized(() => verifyAppleJWS(jws), "pinned Apple root");
});

Deno.test("swapping in a self-signed leaf does not shortcut the chain", async () => {
  const chain = await buildChain();
  // A root that is genuinely trusted, presented with certificates from another
  // chain: the intermediate no longer verifies under it.
  const foreign = await buildChain();
  const jws = await signJws(
    { ...foreign, rootDer: chain.rootDer },
    transactionPayload(),
  );
  await expectUnauthorized(() => verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
});

// ── Certificate validity ────────────────────────────────────────────────────

Deno.test("an expired leaf is rejected", async () => {
  const chain = await buildChain({ expiredLeaf: true });
  const jws = await signJws(chain, transactionPayload());
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer }),
    "leaf certificate has expired",
  );
});

Deno.test("a chain that is not yet valid is rejected", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());
  // Same chain, evaluated two years before it was issued.
  await expectUnauthorized(
    () => verifyAppleJWS(jws, {
      trustRoot: chain.rootDer,
      now: new Date(Date.now() - 2 * YEAR),
    }),
    "not yet valid",
  );
});

// ── Signature integrity ─────────────────────────────────────────────────────

Deno.test("a tampered payload is rejected", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());
  const [h, p, s] = jws.split(".");

  // Re-encode the payload with an upgraded plan, keeping the original signature.
  const forged = b64url(new TextEncoder().encode(JSON.stringify(
    transactionPayload({ productId: "com.rendprop.app.team.annual" }),
  )));
  assert(forged !== p, "the forged payload must differ from the signed one");
  await expectUnauthorized(
    () => verifyAppleJWS(`${h}.${forged}.${s}`, { trustRoot: chain.rootDer }),
    "payload signature",
  );

  // A single flipped BIT in the signature is equally fatal.
  //
  // S1 review: this used to flip the last base64url CHARACTER. A 64-byte ES256
  // signature is 86 base64url characters and the last one carries 4 significant
  // bits plus 2 of padding — so `A` -> `B` changed only padding, the decoded 64
  // bytes were identical, the signature still verified, and the assertion
  // failed. It did that on roughly one run in six (measured, 12 runs of the
  // committed file), which is a test that says it proves something and does not.
  // Flip a real byte instead.
  const sigBytes = decodeB64Url(s);
  sigBytes[0] ^= 0x01;
  const flipped = b64url(sigBytes);
  assert(flipped !== s, "the flipped signature must differ from the real one");
  await expectUnauthorized(() => verifyAppleJWS(`${h}.${p}.${flipped}`, { trustRoot: chain.rootDer }));
});

Deno.test("a certificate whose signature was re-issued by the wrong key is rejected", async () => {
  const chain = await buildChain();
  const impostor = await buildChain();
  // Real root + real leaf, but an intermediate signed by somebody else's root.
  const jws = await signJws(
    { ...chain, intermediateDer: impostor.intermediateDer },
    transactionPayload(),
  );
  await expectUnauthorized(() => verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
});

// ── The Apple marker extensions ─────────────────────────────────────────────

Deno.test("a leaf without the App Store marker OID is rejected", async () => {
  const chain = await buildChain({ omitLeafMarker: true });
  const jws = await signJws(chain, transactionPayload());
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer }),
    "not an App Store signing certificate",
  );
});

Deno.test("an intermediate without the WWDR marker OID is rejected", async () => {
  const chain = await buildChain({ omitIntermediateMarker: true });
  const jws = await signJws(chain, transactionPayload());
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer }),
    "not the Apple WWDR CA",
  );
});

Deno.test("an intermediate that is not a CA is rejected", async () => {
  const chain = await buildChain({ intermediateNotCa: true });
  const jws = await signJws(chain, transactionPayload());
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer }),
    "not a CA",
  );
});

// ── Envelope shape ──────────────────────────────────────────────────────────

Deno.test("the envelope must be ES256 with a 3-certificate x5c", async () => {
  const chain = await buildChain();

  const wrongAlg = await signJws(chain, transactionPayload(), { alg: "RS256" });
  await expectUnauthorized(
    () => verifyAppleJWS(wrongAlg, { trustRoot: chain.rootDer }),
    "alg must be ES256",
  );

  const shortChain = await signJws(chain, transactionPayload(), {
    x5c: [b64(chain.leafDer), b64(chain.intermediateDer)],
  });
  await expectUnauthorized(
    () => verifyAppleJWS(shortChain, { trustRoot: chain.rootDer }),
    "3-certificate chain",
  );

  for (const junk of ["", "not-a-jws", "a.b", "a.b.c.d"]) {
    await expectUnauthorized(() => verifyAppleJWS(junk, { trustRoot: chain.rootDer }));
  }
});

Deno.test("the trust-root override only accepts real bytes", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());
  // A value that survived JSON.parse could only ever be a string/array/object.
  await expectUnauthorized(
    () =>
      verifyAppleJWS(jws, {
        trustRoot: b64(chain.rootDer) as unknown as Uint8Array,
      }),
    "trust root override",
  );
});

// ── What the CALLERS then check ─────────────────────────────────────────────
//
// Bundle id and product mapping are the handler's job, not the verifier's: a
// perfectly signed transaction for another app, or for a product we do not
// sell, is a 400 and not a 401. These assert the inputs those handlers branch
// on are decoded correctly.

Deno.test("a transaction for another bundle id decodes, so the caller can refuse it", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload({ bundleId: "com.someoneelse.app" }));

  const tx = decodeTransaction(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(tx.bundleId, "com.someoneelse.app");
  assert(tx.bundleId !== BUNDLE_ID, "the handler's bundle check must fail on this");
});

Deno.test("product ids map to plans, and anything else maps to null", () => {
  assertEquals(productToPlan("com.rendprop.app.starter.monthly"), "starter");
  assertEquals(productToPlan("com.rendprop.app.starter.annual"), "starter");
  assertEquals(productToPlan("com.rendprop.app.pro.monthly"), "pro");
  assertEquals(productToPlan("com.rendprop.app.pro.annual"), "pro");
  assertEquals(productToPlan("com.rendprop.app.team.monthly"), "team");
  assertEquals(productToPlan("com.rendprop.app.team.annual"), "team");
  // `solo` is a legacy alias of starter and is never sold; `trial` and `free`
  // are not products at all.
  assertEquals(productToPlan("com.rendprop.app.solo.monthly"), null);
  assertEquals(productToPlan("com.rendprop.app.trial"), null);
  assertEquals(productToPlan("com.rendprop.app.pro"), null);
  assertEquals(productToPlan(""), null);
  assertEquals(productToPlan(null), null);
  assertEquals(productToPlan(undefined), null);
});

Deno.test("a non-subscription purchase has no expiresDate, so the caller can refuse it", async () => {
  const chain = await buildChain();
  const p = transactionPayload({ type: "Non-Consumable" });
  delete p.expiresDate;
  const jws = await signJws(chain, p);

  const tx = decodeTransaction(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(tx.expiresDate, null);
  assertEquals(tx.type, "Non-Consumable");
});

Deno.test("timestamps that are not sane millisecond epochs decode as null", async () => {
  const chain = await buildChain();
  const jws = await signJws(
    chain,
    transactionPayload({
      // Seconds instead of milliseconds (1970-01-20), a string, and zero: three
      // ways a wrong expiry could silently become a plausible date.
      expiresDate: Math.floor(Date.now() / 1000),
      purchaseDate: "2026-01-01T00:00:00Z",
      revocationDate: 0,
    }),
  );
  const tx = decodeTransaction(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(tx.expiresDate, null);
  assertEquals(tx.purchaseDate, null);
  assertEquals(tx.revocationDate, null);
});

Deno.test("a revoked transaction carries its revocation date", async () => {
  const chain = await buildChain();
  const revokedAt = Date.now() - HOUR;
  const jws = await signJws(
    chain,
    transactionPayload({ revocationDate: revokedAt, revocationReason: 1 }),
  );
  const tx = decodeTransaction(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(tx.revocationDate, new Date(revokedAt).toISOString());
  assertEquals(tx.revocationReason, 1);
});

Deno.test("a transaction missing its identity fields is rejected", async () => {
  const chain = await buildChain();
  const p = transactionPayload();
  delete p.productId;
  const jws = await signJws(chain, p);
  const payload = await verifyAppleJWS(jws, { trustRoot: chain.rootDer });
  await expectUnauthorized(async () => decodeTransaction(payload), "identity fields");
});

// ── deriveEntitlement: the rule both callers share ──────────────────────────
//
// POST /me/entitlement and POST /apple-subscriptions/notify both answer "is
// this workspace paid up, and until when?" from the same two payloads. These
// assert the answer, since a wrong one either bills nobody or locks out a
// paying customer.

const NOW = new Date("2026-09-05T12:00:00.000Z");
const FUTURE = "2026-10-05T12:00:00.000Z";
const PAST = "2026-08-05T12:00:00.000Z";

function tx(over: Partial<AppleTransaction> = {}): AppleTransaction {
  return {
    transactionId: "T1",
    originalTransactionId: "OT1",
    productId: "com.rendprop.app.pro.monthly",
    bundleId: BUNDLE_ID,
    environment: "Production",
    purchaseDate: PAST,
    expiresDate: FUTURE,
    revocationDate: null,
    revocationReason: null,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    appAccountToken: null,
    webOrderLineItemId: null,
    subscriptionGroupIdentifier: null,
    signedDate: PAST,
    ...over,
  };
}

function renewal(over: Partial<AppleRenewalInfo> = {}): AppleRenewalInfo {
  return {
    originalTransactionId: "OT1",
    productId: "com.rendprop.app.pro.monthly",
    autoRenewProductId: "com.rendprop.app.pro.monthly",
    autoRenewStatus: 1,
    renewalDate: FUTURE,
    gracePeriodExpiresDate: null,
    expirationIntent: null,
    isInBillingRetryPeriod: null,
    priceIncreaseStatus: null,
    offerIdentifier: null,
    offerType: null,
    environment: "Production",
    signedDate: PAST,
    ...over,
  };
}

Deno.test("an unexpired transaction is active until its expiry", () => {
  const e = deriveEntitlement(tx(), renewal(), { now: NOW });
  assertEquals(e.status, "active");
  assertEquals(e.expiresAt, FUTURE);
  assertEquals(e.autoRenew, true);
});

Deno.test("an expired transaction inside a grace window keeps the plan until the grace ends", () => {
  const graceEnd = "2026-09-19T12:00:00.000Z"; // 14 days out, inside Apple's 16
  const e = deriveEntitlement(
    tx({ expiresDate: PAST }),
    renewal({ autoRenewStatus: 0, gracePeriodExpiresDate: graceEnd, isInBillingRetryPeriod: true }),
    { now: NOW },
  );
  assertEquals(e.status, "grace");
  // Access until the GRACE ends, not until the paid period ended — this value
  // becomes orgs.plan_expires_at, so it has to mean "access until".
  assertEquals(e.expiresAt, graceEnd);
  assertEquals(e.autoRenew, false);
});

Deno.test("an expired transaction whose grace has also passed is expired", () => {
  const e = deriveEntitlement(
    tx({ expiresDate: PAST }),
    renewal({ gracePeriodExpiresDate: "2026-08-20T12:00:00.000Z" }),
    { now: NOW },
  );
  assertEquals(e.status, "expired");
  assertEquals(e.expiresAt, PAST);
});

Deno.test("an expired transaction with no renewal info is expired, and auto-renew is unknown", () => {
  const e = deriveEntitlement(tx({ expiresDate: PAST }), null, { now: NOW });
  assertEquals(e.status, "expired");
  // null, not false: the caller must not clobber a stored auto_renew with a guess.
  assertEquals(e.autoRenew, null);
});

Deno.test("a revoked transaction is terminal, and the caller picks refund vs revoke", () => {
  const revokedAt = "2026-09-01T00:00:00.000Z";
  const base = tx({ revocationDate: revokedAt, revocationReason: 1 });

  const refund = deriveEntitlement(base, renewal(), { now: NOW });
  assertEquals(refund.status, "refunded");
  assertEquals(refund.expiresAt, revokedAt);

  const revoke = deriveEntitlement(base, renewal(), { now: NOW, revoked: true });
  assertEquals(revoke.status, "revoked");
  assertEquals(revoke.expiresAt, revokedAt);

  // A revocation wins even while the paid period is still running.
  assertEquals(deriveEntitlement(base, null, { now: NOW }).status, "refunded");
});

Deno.test("a transaction with no dates at all is expired, not accidentally active", () => {
  const e = deriveEntitlement(tx({ expiresDate: null }), null, { now: NOW });
  assertEquals(e.status, "expired");
  assertEquals(e.expiresAt, null);
});

// ── S1 adversarial review (2026-09-05) ───────────────────────────────────────
//
// Everything below is an attack that was TRIED against verifyAppleJWS() during
// the pre-money security review. All of them are refused; the tests are here so
// they stay refused. They use the same throwaway chain factory as the suite
// above — no Apple key exists, so a synthetic root plus the real embedded one
// is the only way to prove both halves.

Deno.test("S1: alg confusion — none, HS256 and ES384 are all refused", async () => {
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());
  const [, payload, signature] = jws.split(".");

  for (const alg of ["none", "HS256", "ES384", "RS256", "", null]) {
    const header = b64url(new TextEncoder().encode(JSON.stringify({
      alg,
      x5c: [b64(chain.leafDer), b64(chain.intermediateDer), b64(chain.rootDer)],
    })));
    await expectUnauthorized(
      () => verifyAppleJWS(`${header}.${payload}.${signature}`, { trustRoot: chain.rootDer }),
      "alg must be ES256",
    );
  }
});

Deno.test("S1: an x5c of 2 or 4 certificates is refused, and so is a swapped order", async () => {
  const chain = await buildChain();
  const payload = transactionPayload();

  const two = await signJws(chain, payload, {
    x5c: [b64(chain.leafDer), b64(chain.rootDer)],
  });
  await expectUnauthorized(() => verifyAppleJWS(two, { trustRoot: chain.rootDer }), "3-certificate");

  const four = await signJws(chain, payload, {
    x5c: [b64(chain.leafDer), b64(chain.intermediateDer), b64(chain.rootDer), b64(chain.rootDer)],
  });
  await expectUnauthorized(() => verifyAppleJWS(four, { trustRoot: chain.rootDer }), "3-certificate");

  // leaf and intermediate swapped: the root still pins, the linkage does not.
  const swapped = await signJws(chain, payload, {
    x5c: [b64(chain.intermediateDer), b64(chain.leafDer), b64(chain.rootDer)],
  });
  await expectUnauthorized(() => verifyAppleJWS(swapped, { trustRoot: chain.rootDer }));
});

Deno.test("S1: a self-signed root with Apple's own subject name does not pin", async () => {
  // The whole point of BYTE equality rather than "chains to a name we trust":
  // an attacker can mint a root whose subject DN is character-for-character
  // Apple's, sign a whole chain under it, and it must still be refused.
  const key = await generateKey();
  const now = new Date();
  const impostorRoot = await makeCert({
    subject: "Apple Root CA - G3",
    issuer: "Apple Root CA - G3",
    subjectKey: key,
    issuerKey: key,
    serial: 1,
    notBefore: new Date(now.getTime() - YEAR),
    notAfter: new Date(now.getTime() + YEAR),
    extensions: [caExtension()],
  });
  const intermediate = await generateKey();
  const leaf = await generateKey();
  const impostorIntermediate = await makeCert({
    subject: "Apple Worldwide Developer Relations Certification Authority",
    issuer: "Apple Root CA - G3",
    subjectKey: intermediate,
    issuerKey: key,
    serial: 2,
    notBefore: new Date(now.getTime() - YEAR),
    notAfter: new Date(now.getTime() + YEAR),
    extensions: [caExtension(), markerExtension(OID_INTERMEDIATE_MARKER)],
  });
  const impostorLeaf = await makeCert({
    subject: "Prod ECC Mac App Store and iTunes Store Receipt Signing",
    issuer: "Apple Worldwide Developer Relations Certification Authority",
    subjectKey: leaf,
    issuerKey: intermediate,
    serial: 3,
    notBefore: new Date(now.getTime() - YEAR),
    notAfter: new Date(now.getTime() + YEAR),
    extensions: [markerExtension(OID_LEAF_MARKER)],
  });

  const forged: Chain = {
    rootDer: impostorRoot,
    intermediateDer: impostorIntermediate,
    leafDer: impostorLeaf,
    leafKey: leaf,
  };
  const jws = await signJws(forged, transactionPayload());
  // No trustRoot override: this is the production check, against the real pin.
  await expectUnauthorized(() => verifyAppleJWS(jws), "pinned Apple root");
});

Deno.test("S1: a leaf whose key did not sign the JWS is refused", async () => {
  // A perfectly valid chain, but the envelope was signed with a different key —
  // the classic "attach someone else's certificate" attack.
  const chain = await buildChain();
  const other = await buildChain();
  const jws = await signJws(
    { ...chain, leafKey: other.leafKey },
    transactionPayload(),
  );
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer }),
    "payload signature",
  );
});

Deno.test("S1: the payload is only parsed AFTER the signature verifies", async () => {
  // A payload that is not even JSON must produce a SIGNATURE failure, not a
  // parse failure — proof that nothing reads the payload before the crypto.
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload());
  const [header, , signature] = jws.split(".");
  const junk = b64url(new TextEncoder().encode("not json at all"));
  await expectUnauthorized(
    () => verifyAppleJWS(`${header}.${junk}.${signature}`, { trustRoot: chain.rootDer }),
    "payload signature",
  );
});

Deno.test("S1: a JWS larger than the cap is refused before any parsing", async () => {
  await expectUnauthorized(() => verifyAppleJWS("a".repeat(64 * 1024 + 1)), "envelope size");
  await expectUnauthorized(() => verifyAppleJWS(""), "envelope size");
});

Deno.test("S1: duplicate and prototype-shaped payload keys cannot poison the decode", async () => {
  const chain = await buildChain();
  // JSON.parse keeps the LAST duplicate and defines __proto__ as an own
  // property rather than setting the prototype — assert both, because the
  // decoders read these fields by name.
  const raw = JSON.stringify({
    ...transactionPayload(),
    productId: "com.rendprop.app.starter.monthly",
  }).replace(
    '"productId":"com.rendprop.app.starter.monthly"',
    '"productId":"com.rendprop.app.team.monthly","productId":"com.rendprop.app.starter.monthly",' +
      '"__proto__":{"bundleId":"com.evil.app"},"constructor":{"x":1}',
  );
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({
    alg: "ES256",
    x5c: [b64(chain.leafDer), b64(chain.intermediateDer), b64(chain.rootDer)],
  })));
  const payload = b64url(enc.encode(raw));
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      chain.leafKey.privateKey,
      enc.encode(`${header}.${payload}`),
    ),
  );
  const decoded = decodeTransaction(
    await verifyAppleJWS(`${header}.${payload}.${b64url(sig)}`, { trustRoot: chain.rootDer }),
  );
  assertEquals(decoded.productId, "com.rendprop.app.starter.monthly"); // last wins
  assertEquals(decoded.bundleId, BUNDLE_ID); // __proto__ did not become the prototype
  assertEquals(({} as Record<string, unknown>).bundleId, undefined); // nothing global moved
});

Deno.test("S1: productToPlan never resolves off Object.prototype", () => {
  for (const key of ["constructor", "toString", "__proto__", "hasOwnProperty", "valueOf"]) {
    assertEquals(productToPlan(key), null);
  }
});

Deno.test("S1: appAccountToken and a Unicode productId survive the decode intact", async () => {
  const chain = await buildChain();
  const token = "0d1c8f8e-9a6b-4f1e-9d2c-7b3a5e6f0011";
  const jws = await signJws(chain, transactionPayload({
    appAccountToken: token,
    productId: "com.rendprop.app.prо.monthly", // Cyrillic 'о' — a homograph
  }));
  const decoded = decodeTransaction(await verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
  assertEquals(decoded.appAccountToken, token);
  // The homograph is NOT one of the six products we sell, so it maps to no
  // plan and POST /me/entitlement 400s it.
  assertEquals(productToPlan(decoded.productId), null);
});

Deno.test("S1: a chain valid an hour ago is refused once `now` moves past it", async () => {
  const chain = await buildChain({ now: new Date("2020-01-01T00:00:00Z") });
  const jws = await signJws(chain, transactionPayload());
  await expectUnauthorized(
    () => verifyAppleJWS(jws, { trustRoot: chain.rootDer, now: new Date("2026-09-05T00:00:00Z") }),
    "expired",
  );
  // …and accepted inside the window, so the failure above is the clock and not
  // something else in the chain.
  const ok = await verifyAppleJWS(jws, {
    trustRoot: chain.rootDer,
    now: new Date("2020-01-02T00:00:00Z"),
  });
  assertEquals(typeof ok.transactionId, "string");
});

Deno.test("S1: an x5c entry in base64URL rather than base64 is refused", async () => {
  // x5c is standard base64 per RFC 7515. Accepting base64url as well would be a
  // second decoding path into the certificate parser for no reason.
  const chain = await buildChain();
  const jws = await signJws(chain, transactionPayload(), {
    x5c: [b64url(chain.leafDer), b64(chain.intermediateDer), b64(chain.rootDer)],
  });
  await expectUnauthorized(() => verifyAppleJWS(jws, { trustRoot: chain.rootDer }));
});
