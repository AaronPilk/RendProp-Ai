// applejws.ts — verify and decode the JWS blobs Apple signs.
//
// Three kinds of signed payload land on this server and all three use the SAME
// envelope, so they all come through verifyAppleJWS():
//
//   • StoreKit 2 `Transaction.jwsRepresentation`     (POST /me/entitlement)
//   • StoreKit 2 `RenewalInfo.jwsRepresentation`     (POST /me/entitlement)
//   • App Store Server Notifications V2 signedPayload + its two nested
//     `data.signedTransactionInfo` / `data.signedRenewalInfo` blobs
//     (POST /apple-subscriptions/notify)
//
// The envelope is a compact JWS whose protected header carries `alg: "ES256"`
// and an `x5c` chain of exactly three base64 (NOT base64url) DER certificates:
// leaf → Apple Worldwide Developer Relations intermediate → Apple Root CA - G3.
//
// ── WHAT IS CHECKED, AND WHY EACH CHECK IS HERE ─────────────────────────────
//
//   1. ROOT PINNING. x5c[2] must be BYTE-EQUAL to the Apple Root CA - G3
//      certificate embedded below. Not "chains to a trusted store", not "has
//      the right subject" — the same 583 bytes. Anything else and the whole
//      verification is theatre, because an attacker who can pick the root can
//      mint the other two.
//   2. intermediate is signed by the root, leaf is signed by the intermediate.
//      Real ECDSA verification through WebCrypto, with the hash taken from each
//      certificate's own signatureAlgorithm OID (Apple currently uses
//      ecdsa-with-SHA384 throughout; SHA-256 and SHA-512 are accepted too so a
//      future rotation is not an outage).
//   3. Issuer/subject linkage: each certificate's issuer Name must be the
//      byte-identical DER of its issuer's subject Name.
//   4. The intermediate must be a CA (basicConstraints cA = TRUE), so a leaf
//      can never be used to sign another certificate.
//   5. Validity windows of all three certificates against `now`, with the same
//      60-second clock skew Apple's own library allows.
//   6. Marker extensions. The leaf must carry OID 1.2.840.113635.100.6.11.1
//      and the intermediate OID 1.2.840.113635.100.6.2.1. These are the exact
//      two OIDs apple/app-store-server-library-node checks in
//      `verifyCertificateChainWithoutCaching` (jws_verification.ts, lines
//      290-291, read 2026-09-05). Without them, ANY certificate Apple's WWDR CA
//      has ever issued — every developer's distribution certificate — would be
//      accepted as a receipt signer.
//   7. The leaf's P-256 key must actually sign the JWS (ECDSA / SHA-256).
//
// NOT checked, deliberately: OCSP revocation. Apple's library only does it when
// `enableOnlineChecks` is on; it adds a hard dependency on ocsp.apple.com to
// every purchase, and a revoked Apple signing leaf is a scenario in which Apple
// re-signs and re-sends. Written down here rather than left as a silent gap.
//
// Validity is checked against `now`, not against the payload's own signedDate
// (which is what Apple's library uses when online checks are off). Everything
// this server verifies is fresh — a device that just bought, or a notification
// Apple is delivering or retrying within ~3 days — and Apple's signing leaves
// are valid for about a year, so `now` is both correct and strictly tighter.
//
// Apple Root CA - G3, fetched 2026-09-05 from
// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
//   SHA-256  63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:
//            7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
//   subject  CN=Apple Root CA - G3, OU=Apple Certification Authority,
//            O=Apple Inc., C=US   (self-issued, secp384r1, ecdsa-with-SHA384)
//   valid    2014-04-30T18:19:06Z → 2039-04-30T18:19:06Z
// The fingerprint above is asserted by applejws.test.ts, so a bad paste of the
// base64 below fails the test suite rather than production.
//
// No credential of any kind is read, written or logged by this module.

import { HttpError } from "./http.ts";

// ── The pinned root ─────────────────────────────────────────────────────────

const APPLE_ROOT_CA_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9v" +
  "dCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UE" +
  "CgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2" +
  "WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmlj" +
  "YXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqG" +
  "SM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxE" +
  "tX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNC" +
  "MEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P" +
  "AQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3m" +
  "eoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL" +
  "F1vLUagM6BgD56KyKA==";

/** The pinned Apple Root CA - G3, as DER bytes. */
export const APPLE_ROOT_CA_G3_DER: Uint8Array<ArrayBuffer> = decodeBase64(APPLE_ROOT_CA_G3_B64);

/** Leaf marker: App Store receipt / server signing. */
const OID_APPLE_LEAF_MARKER = "1.2.840.113635.100.6.11.1";
/** Intermediate marker: Apple Worldwide Developer Relations CA. */
const OID_APPLE_INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";

const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";

const CURVE_BY_OID: Record<string, { name: NamedCurve; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
  "1.3.132.0.35": { name: "P-521", size: 66 },
};

const HASH_BY_SIG_OID: Record<string, string> = {
  "1.2.840.10045.4.3.2": "SHA-256", // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": "SHA-384", // ecdsa-with-SHA384
  "1.2.840.10045.4.3.4": "SHA-512", // ecdsa-with-SHA512
};

type NamedCurve = "P-256" | "P-384" | "P-521";

/** Clock skew Apple's own library allows on certificate validity windows. */
const MAX_SKEW_MS = 60_000;

/** Defensive size caps — a JWS is a few KB; anything larger is not ours. */
const MAX_JWS_CHARS = 64 * 1024;
const MAX_CERT_BYTES = 8 * 1024;

// ── Errors ──────────────────────────────────────────────────────────────────

/**
 * Every failure in this module is the same thing to a caller: the blob is not
 * trustworthy. Detail stays in the message (it names a check, never any input),
 * status is always 401 so a handler can not accidentally leak the difference
 * between "bad signature" and "expired certificate".
 */
function reject(what: string): never {
  throw new HttpError(401, `Apple signature could not be verified (${what})`, "unauthorized");
}

// ── base64 / base64url ──────────────────────────────────────────────────────

/**
 * An ArrayBuffer-backed byte array. TypeScript 5.7 made Uint8Array generic over
 * its buffer, and WebCrypto's BufferSource only accepts the ArrayBuffer flavour
 * — so every byte string that reaches crypto.subtle carries this type rather
 * than a cast at each call site.
 */
type Bytes = Uint8Array<ArrayBuffer>;

function decodeBase64(s: string): Bytes {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function decodeBase64Url(s: string): Bytes {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return decodeBase64(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
}

// ── Minimal DER reader ──────────────────────────────────────────────────────
//
// Enough of X.690 to walk an X.509 certificate: definite-length TLVs only (DER
// forbids indefinite lengths), lengths up to 4 bytes, no BER re-assembly. Every
// malformed shape throws, so a truncated or hand-crafted certificate can never
// be read as a shorter, valid one.

interface Tlv {
  tag: number;
  start: number;
  contentStart: number;
  contentEnd: number;
  end: number;
}

function readTlv(buf: Uint8Array, offset: number): Tlv {
  if (offset + 2 > buf.length) reject("truncated DER");
  const tag = buf[offset];
  let p = offset + 1;
  let len = buf[p++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) reject("unsupported DER length");
    if (p + n > buf.length) reject("truncated DER length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[p++];
  }
  const contentStart = p;
  const contentEnd = p + len;
  if (contentEnd > buf.length) reject("truncated DER content");
  return { tag, start: offset, contentStart, contentEnd, end: contentEnd };
}

function childrenOf(buf: Uint8Array, node: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let p = node.contentStart;
  while (p < node.contentEnd) {
    const c = readTlv(buf, p);
    if (c.end <= p) reject("zero-length DER node");
    out.push(c);
    p = c.end;
  }
  if (p !== node.contentEnd) reject("DER children overrun");
  return out;
}

function bytesOf(buf: Bytes, node: Tlv): Bytes {
  // Copy: WebCrypto and byte comparison both want a standalone buffer.
  return buf.slice(node.start, node.end);
}

function contentOf(buf: Bytes, node: Tlv): Bytes {
  return buf.slice(node.contentStart, node.contentEnd);
}

function oidToString(buf: Uint8Array, node: Tlv): string {
  if (node.tag !== 0x06) reject("expected an OID");
  const b = buf.subarray(node.contentStart, node.contentEnd);
  if (b.length === 0) reject("empty OID");
  const first = b[0];
  const parts: number[] = first >= 80 ? [2, first - 80] : [Math.floor(first / 40), first % 40];
  let v = 0;
  for (let i = 1; i < b.length; i++) {
    v = v * 128 + (b[i] & 0x7f);
    if ((b[i] & 0x80) === 0) {
      parts.push(v);
      v = 0;
    }
  }
  return parts.join(".");
}

/** UTCTime (0x17) / GeneralizedTime (0x18) → epoch ms. */
function parseAsn1Time(buf: Uint8Array, node: Tlv): number {
  const s = new TextDecoder().decode(buf.subarray(node.contentStart, node.contentEnd));
  let iso: string;
  if (node.tag === 0x17) {
    const m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?Z$/.exec(s);
    if (!m) reject("bad UTCTime");
    const yy = Number(m![1]);
    const year = yy < 50 ? 2000 + yy : 1900 + yy;
    iso = `${String(year).padStart(4, "0")}-${m![2]}-${m![3]}T${m![4]}:${m![5]}:${m![6] ?? "00"}Z`;
  } else if (node.tag === 0x18) {
    const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?(?:\.\d+)?Z$/.exec(s);
    if (!m) reject("bad GeneralizedTime");
    iso = `${m![1]}-${m![2]}-${m![3]}T${m![4]}:${m![5]}:${m![6] ?? "00"}Z`;
  } else {
    reject("unsupported time type");
  }
  const t = Date.parse(iso!);
  if (!Number.isFinite(t)) reject("unparseable certificate time");
  return t;
}

// ── X.509 ───────────────────────────────────────────────────────────────────

interface ParsedCert {
  der: Bytes;
  /** The exact TBSCertificate bytes the signature covers. */
  tbs: Bytes;
  sigAlgOid: string;
  /** Raw ECDSA signature (DER SEQUENCE { r, s }) from the outer BIT STRING. */
  signature: Bytes;
  spki: Bytes;
  curve: NamedCurve;
  curveSize: number;
  issuerDer: Bytes;
  subjectDer: Bytes;
  notBefore: number;
  notAfter: number;
  extensionOids: Set<string>;
  isCa: boolean;
}

function parseCertificate(der: Bytes): ParsedCert {
  if (der.length === 0 || der.length > MAX_CERT_BYTES) reject("certificate size");
  const cert = readTlv(der, 0);
  if (cert.tag !== 0x30) reject("certificate is not a SEQUENCE");
  const top = childrenOf(der, cert);
  if (top.length !== 3) reject("certificate must hold tbs + algorithm + signature");
  const [tbsNode, algNode, sigNode] = top;
  if (tbsNode.tag !== 0x30 || algNode.tag !== 0x30 || sigNode.tag !== 0x03) {
    reject("certificate shape");
  }

  const algOid = oidToString(der, childrenOf(der, algNode)[0]);

  // BIT STRING: first content byte is the unused-bit count, which is 0 here.
  const sigContent = contentOf(der, sigNode);
  if (sigContent.length < 2 || sigContent[0] !== 0) reject("signature BIT STRING");
  const signature = sigContent.slice(1);

  const tbsKids = childrenOf(der, tbsNode);
  let i = 0;
  if (tbsKids[i]?.tag === 0xa0) i++; // [0] EXPLICIT version
  const serial = tbsKids[i++];
  const innerAlg = tbsKids[i++];
  const issuer = tbsKids[i++];
  const validity = tbsKids[i++];
  const subject = tbsKids[i++];
  const spkiNode = tbsKids[i++];
  if (!serial || !innerAlg || !issuer || !validity || !subject || !spkiNode) {
    reject("TBSCertificate shape");
  }
  // RFC 5280 §4.1.1.2: the inner and outer algorithm identifiers must agree.
  if (oidToString(der, childrenOf(der, innerAlg)[0]) !== algOid) {
    reject("signature algorithm mismatch");
  }

  const [nb, na] = childrenOf(der, validity);
  if (!nb || !na) reject("validity shape");
  const notBefore = parseAsn1Time(der, nb);
  const notAfter = parseAsn1Time(der, na);

  // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
  const spkiKids = childrenOf(der, spkiNode);
  const spkiAlg = childrenOf(der, spkiKids[0]);
  if (oidToString(der, spkiAlg[0]) !== OID_EC_PUBLIC_KEY) reject("public key is not EC");
  if (!spkiAlg[1]) reject("EC key has no named curve");
  const curve = CURVE_BY_OID[oidToString(der, spkiAlg[1])];
  if (!curve) reject("unsupported EC curve");

  // Extensions live in the optional [3] EXPLICIT tail.
  const extensionOids = new Set<string>();
  let isCa = false;
  for (let k = i; k < tbsKids.length; k++) {
    if (tbsKids[k].tag !== 0xa3) continue;
    const extSeq = childrenOf(der, tbsKids[k])[0];
    if (!extSeq || extSeq.tag !== 0x30) reject("extensions shape");
    for (const ext of childrenOf(der, extSeq)) {
      const parts = childrenOf(der, ext);
      const oid = oidToString(der, parts[0]);
      extensionOids.add(oid);
      if (oid !== OID_BASIC_CONSTRAINTS) continue;
      // Extension ::= SEQUENCE { extnID, critical DEFAULT FALSE, extnValue OCTET STRING }
      const valueNode = parts[parts.length - 1];
      if (valueNode.tag !== 0x04) reject("extension value");
      const inner = contentOf(der, valueNode);
      const bc = readTlv(inner, 0);
      if (bc.tag !== 0x30) reject("basicConstraints");
      const bcKids = childrenOf(inner, bc);
      isCa = bcKids.length > 0 && bcKids[0].tag === 0x01 &&
        inner[bcKids[0].contentStart] !== 0x00;
    }
  }

  return {
    der,
    tbs: bytesOf(der, tbsNode),
    sigAlgOid: algOid,
    signature,
    spki: bytesOf(der, spkiNode),
    curve: curve.name,
    curveSize: curve.size,
    issuerDer: bytesOf(der, issuer),
    subjectDer: bytesOf(der, subject),
    notBefore,
    notAfter,
    extensionOids,
    isCa,
  };
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** DER SEQUENCE { INTEGER r, INTEGER s } → the fixed-width r‖s WebCrypto wants. */
function ecdsaDerToRaw(der: Bytes, size: number): Bytes {
  const seq = readTlv(der, 0);
  if (seq.tag !== 0x30 || seq.end !== der.length) reject("ECDSA signature shape");
  const kids = childrenOf(der, seq);
  if (kids.length !== 2 || kids[0].tag !== 0x02 || kids[1].tag !== 0x02) {
    reject("ECDSA signature shape");
  }
  const out = new Uint8Array(size * 2);
  for (let k = 0; k < 2; k++) {
    const src = der.subarray(kids[k].contentStart, kids[k].contentEnd);
    let s = 0;
    while (s < src.length - 1 && src[s] === 0) s++;
    const v = src.subarray(s);
    if (v.length > size || v.length === 0) reject("ECDSA signature component size");
    out.set(v, k * size + size - v.length);
  }
  return out;
}

async function importEcPublicKey(cert: ParsedCert): Promise<CryptoKey> {
  try {
    return await crypto.subtle.importKey(
      "spki",
      cert.spki,
      { name: "ECDSA", namedCurve: cert.curve },
      false,
      ["verify"],
    );
  } catch {
    reject("public key import");
  }
}

/** True when `child` really was signed by `issuer`. */
async function signedBy(child: ParsedCert, issuer: ParsedCert): Promise<boolean> {
  const hash = HASH_BY_SIG_OID[child.sigAlgOid];
  if (!hash) reject("unsupported certificate signature algorithm");
  const key = await importEcPublicKey(issuer);
  const raw = ecdsaDerToRaw(child.signature, issuer.curveSize);
  return await crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, child.tbs);
}

function assertWithinValidity(cert: ParsedCert, nowMs: number, which: string): void {
  if (cert.notBefore > nowMs + MAX_SKEW_MS) reject(`${which} certificate is not yet valid`);
  if (cert.notAfter < nowMs - MAX_SKEW_MS) reject(`${which} certificate has expired`);
}

// ── The public entry point ──────────────────────────────────────────────────

export interface VerifyAppleJWSOptions {
  /** Clock to check certificate validity windows against. Defaults to `new Date()`. */
  now?: Date;
  /**
   * TEST ONLY. Replaces the pinned Apple Root CA - G3 with another root, so
   * applejws.test.ts can mint a throwaway chain instead of shipping a copy of
   * Apple's private key (which does not exist).
   *
   * This is safe because it is UNREACHABLE FROM A REQUEST: nothing in
   * functions/me or functions/apple-subscriptions passes an options object at
   * all, the field is typed as a Uint8Array (JSON.parse can never produce one),
   * and the runtime check below refuses anything else. Do not add a code path
   * that derives this value from a request, an env var, or a database row.
   */
  trustRoot?: Uint8Array;
}

/**
 * Verify an Apple-signed compact JWS and return its decoded payload object.
 * Throws HttpError(401, …, "unauthorized") on ANY failure — a malformed
 * envelope, a chain that does not reach the pinned Apple root, an expired
 * certificate, a missing marker OID, or a bad signature are all the same answer
 * to the caller: do not trust this.
 */
export async function verifyAppleJWS(
  jws: string,
  opts: VerifyAppleJWSOptions = {},
): Promise<Record<string, unknown>> {
  if (typeof jws !== "string" || jws.length === 0 || jws.length > MAX_JWS_CHARS) {
    reject("envelope size");
  }
  const parts = jws.split(".");
  if (parts.length !== 3) reject("envelope is not a compact JWS");

  let header: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[0])));
  } catch {
    reject("header is not JSON");
  }
  if (header!.alg !== "ES256") reject("alg must be ES256");
  const x5c = header!.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    reject("x5c must be a 3-certificate chain");
  }

  let leaf: ParsedCert, intermediate: ParsedCert, rootDer: Bytes, root: ParsedCert;
  try {
    leaf = parseCertificate(decodeBase64((x5c as string[])[0]));
    intermediate = parseCertificate(decodeBase64((x5c as string[])[1]));
    rootDer = decodeBase64((x5c as string[])[2]);
    root = parseCertificate(rootDer);
  } catch (e) {
    if (e instanceof HttpError) throw e;
    reject("certificate parse");
  }

  // 1. Root pinning — byte equality, nothing softer.
  const trusted = opts.trustRoot;
  if (trusted !== undefined && !(trusted instanceof Uint8Array)) {
    reject("trust root override"); // see VerifyAppleJWSOptions.trustRoot
  }
  if (!sameBytes(rootDer!, trusted ?? APPLE_ROOT_CA_G3_DER)) {
    reject("chain does not end at the pinned Apple root");
  }

  const nowMs = (opts.now ?? new Date()).getTime();
  if (!Number.isFinite(nowMs)) reject("clock");

  // 2/3. Linkage + signatures, root → intermediate → leaf.
  if (!sameBytes(intermediate!.issuerDer, root!.subjectDer)) reject("intermediate issuer");
  if (!sameBytes(leaf!.issuerDer, intermediate!.subjectDer)) reject("leaf issuer");
  if (!(await signedBy(intermediate!, root!))) reject("intermediate signature");
  if (!(await signedBy(leaf!, intermediate!))) reject("leaf signature");

  // 4. The intermediate must be a CA; the leaf must not have signed anything.
  if (!intermediate!.isCa) reject("intermediate is not a CA");

  // 5. Validity windows.
  assertWithinValidity(root!, nowMs, "root");
  assertWithinValidity(intermediate!, nowMs, "intermediate");
  assertWithinValidity(leaf!, nowMs, "leaf");

  // 6. Apple's marker extensions (see the header comment for provenance).
  if (!leaf!.extensionOids.has(OID_APPLE_LEAF_MARKER)) {
    reject("leaf is not an App Store signing certificate");
  }
  if (!intermediate!.extensionOids.has(OID_APPLE_INTERMEDIATE_MARKER)) {
    reject("intermediate is not the Apple WWDR CA");
  }

  // 7. The leaf signs the JWS itself.
  if (leaf!.curve !== "P-256") reject("leaf key is not P-256");
  const key = await importEcPublicKey(leaf!);
  const signature = decodeBase64Url(parts[2]);
  if (signature.length !== 64) reject("ES256 signature length");
  const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, signingInput);
  if (!ok) reject("payload signature");

  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[1])));
  } catch {
    reject("payload is not JSON");
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    reject("payload is not an object");
  }
  return payload as Record<string, unknown>;
}

// ── Decoding ────────────────────────────────────────────────────────────────
//
// Apple sends every timestamp as MILLISECONDS since the epoch, as a JSON
// number. msToIso() is deliberately strict: a string, a seconds-scale number,
// 0, or a value outside 1990-2200 all become null rather than a plausible-
// looking wrong date, because these values decide when a subscription lapses.

const MIN_MS = Date.UTC(1990, 0, 1);
const MAX_MS = Date.UTC(2200, 0, 1);

function msToIso(v: unknown): string | null {
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  if (v < MIN_MS || v > MAX_MS) return null;
  return new Date(v).toISOString();
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

export interface AppleTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  /** "Sandbox" | "Production" — stored, never used to decide trust. */
  environment: string;
  purchaseDate: string | null;
  /** null for a non-subscription purchase; callers treat that as a 400. */
  expiresDate: string | null;
  revocationDate: string | null;
  revocationReason: number | null;
  type: string | null;
  /** "PURCHASED" | "FAMILY_SHARED" */
  inAppOwnershipType: string | null;
  appAccountToken: string | null;
  webOrderLineItemId: string | null;
  subscriptionGroupIdentifier: string | null;
  signedDate: string | null;
}

/** Shape a verified JWSTransaction payload. Throws 401 if the identity fields are missing. */
export function decodeTransaction(payload: Record<string, unknown>): AppleTransaction {
  const transactionId = str(payload.transactionId);
  const originalTransactionId = str(payload.originalTransactionId) ?? transactionId;
  const productId = str(payload.productId);
  const bundleId = str(payload.bundleId);
  if (!transactionId || !originalTransactionId || !productId || !bundleId) {
    reject("transaction is missing its identity fields");
  }
  return {
    transactionId: transactionId!,
    originalTransactionId: originalTransactionId!,
    productId: productId!,
    bundleId: bundleId!,
    environment: str(payload.environment) ?? "Production",
    purchaseDate: msToIso(payload.purchaseDate),
    expiresDate: msToIso(payload.expiresDate),
    revocationDate: msToIso(payload.revocationDate),
    revocationReason: num(payload.revocationReason),
    type: str(payload.type),
    inAppOwnershipType: str(payload.inAppOwnershipType),
    appAccountToken: str(payload.appAccountToken),
    webOrderLineItemId: str(payload.webOrderLineItemId),
    subscriptionGroupIdentifier: str(payload.subscriptionGroupIdentifier),
    signedDate: msToIso(payload.signedDate),
  };
}

export interface AppleRenewalInfo {
  originalTransactionId: string | null;
  productId: string | null;
  autoRenewProductId: string | null;
  /** 1 = will renew, 0 = will not. null when Apple did not send it. */
  autoRenewStatus: number | null;
  renewalDate: string | null;
  /** Set while Apple is retrying a failed renewal AND the app has billing grace on. */
  gracePeriodExpiresDate: string | null;
  expirationIntent: number | null;
  isInBillingRetryPeriod: boolean | null;
  priceIncreaseStatus: number | null;
  offerIdentifier: string | null;
  offerType: number | null;
  environment: string | null;
  signedDate: string | null;
}

/** Shape a verified JWSRenewalInfo payload. Every field is optional in practice. */
export function decodeRenewalInfo(payload: Record<string, unknown>): AppleRenewalInfo {
  return {
    originalTransactionId: str(payload.originalTransactionId),
    productId: str(payload.productId),
    autoRenewProductId: str(payload.autoRenewProductId),
    autoRenewStatus: num(payload.autoRenewStatus),
    renewalDate: msToIso(payload.renewalDate),
    gracePeriodExpiresDate: msToIso(payload.gracePeriodExpiresDate),
    expirationIntent: num(payload.expirationIntent),
    isInBillingRetryPeriod: typeof payload.isInBillingRetryPeriod === "boolean"
      ? payload.isInBillingRetryPeriod
      : null,
    priceIncreaseStatus: num(payload.priceIncreaseStatus),
    offerIdentifier: str(payload.offerIdentifier),
    offerType: num(payload.offerType),
    environment: str(payload.environment),
    signedDate: msToIso(payload.signedDate),
  };
}

// ── Apple's signals → our five-word status vocabulary ───────────────────────
//
// Both callers (POST /me/entitlement and POST /apple-subscriptions/notify) have
// to answer the same question — "is this workspace paid up, and until when?" —
// from the same two payloads, so the rules live HERE rather than twice.
//
//   revoked / refunded   the money came back or Family Sharing access was
//                        pulled. Terminal; the caller decides which word,
//                        because only the notification type distinguishes a
//                        REFUND from a REVOKE.
//   active               expiresDate is in the future.
//   grace                expired, but Apple is retrying the charge AND billing
//                        grace is on, so the customer keeps the plan until
//                        gracePeriodExpiresDate. Apple caps that at 16 days,
//                        which is where effective_plan()'s backstop gets its
//                        number (migration 0019 §5).
//   expired              everything else.
//
// `expiresAt` is the instant the ENTITLEMENT ends, not necessarily the instant
// the paid period ended: in grace it is the end of the grace window, and on a
// revocation it is the revocation itself. That is the value that goes into
// orgs.plan_expires_at, so it has to mean "access until".

export type SubscriptionStatus = "active" | "grace" | "expired" | "revoked" | "refunded";

export interface DerivedEntitlement {
  status: SubscriptionStatus;
  /** ISO instant the entitlement ends, or null when Apple sent no dates at all. */
  expiresAt: string | null;
  /** null when no renewal info was supplied — callers must not clobber a stored value. */
  autoRenew: boolean | null;
}

export function deriveEntitlement(
  tx: AppleTransaction,
  renewal: AppleRenewalInfo | null,
  opts: { now?: Date; revoked?: boolean } = {},
): DerivedEntitlement {
  const nowMs = (opts.now ?? new Date()).getTime();
  const autoRenew = renewal && renewal.autoRenewStatus !== null
    ? renewal.autoRenewStatus === 1
    : null;

  if (tx.revocationDate) {
    return {
      status: opts.revoked ? "revoked" : "refunded",
      expiresAt: tx.revocationDate,
      autoRenew,
    };
  }

  const expiresMs = tx.expiresDate ? Date.parse(tx.expiresDate) : NaN;
  if (Number.isFinite(expiresMs) && expiresMs > nowMs) {
    return { status: "active", expiresAt: tx.expiresDate, autoRenew };
  }

  const graceMs = renewal?.gracePeriodExpiresDate
    ? Date.parse(renewal.gracePeriodExpiresDate)
    : NaN;
  if (Number.isFinite(graceMs) && graceMs > nowMs) {
    return { status: "grace", expiresAt: renewal!.gracePeriodExpiresDate, autoRenew };
  }

  return { status: "expired", expiresAt: tx.expiresDate, autoRenew };
}

// ── Products → plans ────────────────────────────────────────────────────────
//
// docs/LAUNCH-CONTRACT.md § "Plans and product IDs". All six products live in
// ONE subscription group (`rendprop_plans`) so Apple manages the upgrade or
// downgrade; the trial is an INTRODUCTORY OFFER on each product, not a product
// of its own, and `free` is the lapsed floor with no product at all. `solo` is
// a legacy alias of starter and is deliberately absent — it is never sold.

const PRODUCT_TO_PLAN: Readonly<Record<string, AppleSoldPlan>> = Object.freeze({
  "com.rendprop.app.starter.monthly": "starter",
  "com.rendprop.app.starter.annual": "starter",
  "com.rendprop.app.pro.monthly": "pro",
  "com.rendprop.app.pro.annual": "pro",
  "com.rendprop.app.team.monthly": "team",
  "com.rendprop.app.team.annual": "team",
});

export type AppleSoldPlan = "starter" | "pro" | "team";

/** The plan a product id grants, or null when the product is not one of ours. */
export function productToPlan(productId: string | null | undefined): AppleSoldPlan | null {
  if (typeof productId !== "string") return null;
  // Own-property lookup. `PRODUCT_TO_PLAN["constructor"]` (or "toString", or
  // "__proto__") resolves off Object.prototype to a FUNCTION, which is neither
  // null nor undefined, so `?? null` would let it through and the caller would
  // treat it as a plan. Apple would have to sign a transaction with that
  // productId for it to matter, so this is depth rather than a hole — but the
  // depth costs one line.
  return Object.prototype.hasOwnProperty.call(PRODUCT_TO_PLAN, productId)
    ? PRODUCT_TO_PLAN[productId]
    : null;
}

/** Every product id this server will honour (for /apple-subscriptions/health). */
export function knownProductIds(): string[] {
  return Object.keys(PRODUCT_TO_PLAN);
}
