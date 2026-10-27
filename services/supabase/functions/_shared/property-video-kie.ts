// Kie Kling 3.0 native-4K property-video quality profile: ONE immutable identity.
//
// Official sources, read 2026-10-16 (no authenticated or paid call):
//  - https://kie.ai/kling-3-0: KIE supplier credits: 4K 67 credits ($0.335)
//    per second with or without audio; Pro silent 18 KIE credits ($0.09) per
//    second; one KIE credit = $0.005; KIE top-up bonus excluded. These are
//    provider cost units, unrelated to Rendprop's customer wallet credits.
//  - https://docs.kie.ai/market/kling/kling-3-0: modes std|pro|4K; image_urls
//    auto-adapt the aspect ratio, so aspect_ratio is omitted (source-auto).
//  - https://docs.kie.ai/market/common/get-task-detail: waiting|queuing|
//    generating|success|fail; errors arrive as HTTP 200 + code; files kept 14 days.
//  - https://kie.ai/terms-of-use section 3: customer content is licensed to Kie
//    "for the purpose of operating and improving our services". The router calls
//    that trains_by_default and refuses customer media; activation therefore needs
//    the exact owner acknowledgement below in app_config, never a silent bypass.
//
// The canonical JSON is shared with SQL (property_video_quality_identity) and the
// disposable-Postgres proof; the runtime TS copy is asserted equal to it, so
// code, database and tests cannot drift apart.
//
// NOTHING here throws at module load. Every function that imports the provider
// registry imports this module, so an inconsistent constant must not take them
// all down: kiePropertyIdentityConsistent() is evaluated on each Kie-profile
// path instead, and each of those paths refuses before any read, hold or POST.
import { KIE_PROPERTY_IDENTITY_SOURCE as source } from "./property-video-kie-identity.ts";

type DeepReadonly<T> = T extends readonly (infer U)[] ? readonly DeepReadonly<U>[]
  : T extends object ? { readonly [K in keyof T]: DeepReadonly<T[K]> }
  : T;

/** A frozen plain-data copy, nested arrays and objects included: neither a
 * caller nor a later mutation of the source module object changes it. */
function deepFrozenCopy<T>(value: T): DeepReadonly<T> {
  if (Array.isArray(value)) return Object.freeze(value.map((item) => deepFrozenCopy(item))) as DeepReadonly<T>;
  if (value !== null && typeof value === "object") {
    const copy: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) copy[key] = deepFrozenCopy(item);
    return Object.freeze(copy) as DeepReadonly<T>;
  }
  return value as DeepReadonly<T>;
}

export const KIE_PROPERTY_IDENTITY = deepFrozenCopy(source);
export type KiePropertyIdentity = typeof KIE_PROPERTY_IDENTITY;
export const KIE_PROPERTY_PROFILE = "kie-kling3-4k-steady-v1" as const;
export const KIE_PROPERTY_ROUTE_ID = KIE_PROPERTY_IDENTITY.route_id;
export const KIE_PROPERTY_TASK = KIE_PROPERTY_IDENTITY.task;
export const KIE_PROPERTY_MODEL = KIE_PROPERTY_IDENTITY.model;
export const KIE_PROPERTY_MODE = KIE_PROPERTY_IDENTITY.mode;
export const KIE_PROPERTY_UNIT_CENTS = KIE_PROPERTY_IDENTITY.unit_cents;
export const KIE_PROPERTY_ATTEMPT_CENTS = KIE_PROPERTY_IDENTITY.attempt_cents;
export const KIE_PROPERTY_CONTENT_LICENSE_ACK = KIE_PROPERTY_IDENTITY.content_license_ack;

const SHA256_HEX = /^[0-9a-f]{64}$/;

/**
 * The identity's own arithmetic and shapes: profile name, 67 KIE credits/s x $0.005
 * = unit_cents, unit_cents x seconds = attempt_cents, a CFR frame budget that
 * contains fps x seconds, positive pixel floors, and a well-formed prompt pin
 * (non-empty token, distinct non-empty nouns without the token, one SHA-256 hex
 * digest per pinned motion). Evaluated lazily by every Kie-profile path.
 */
export function kiePropertyIdentityConsistent(): boolean {
  try {
    const k = KIE_PROPERTY_IDENTITY;
    const token: unknown = k.prompt_template_token;
    const nouns: readonly unknown[] = k.prompt_scene_nouns;
    const pins: readonly unknown[] = Object.values(k.prompt_template_sha256);
    return k.profile === KIE_PROPERTY_PROFILE &&
      k.unit_cents * k.seconds === k.attempt_cents &&
      Math.round(k.credits_per_second * k.usd_per_credit * 100 * 1e4) / 1e4 === k.unit_cents &&
      Number.isInteger(k.output_fps) && k.output_fps > 0 && k.output_frames.every(Number.isInteger) &&
      k.output_frames.includes(k.output_fps * k.seconds) &&
      Number.isFinite(k.min_short_side_px) && k.min_short_side_px > 0 &&
      Number.isFinite(k.min_pixels) && k.min_pixels > 0 &&
      typeof token === "string" && token.length > 0 &&
      nouns.length > 0 && new Set(nouns).size === nouns.length &&
      nouns.every((noun) => typeof noun === "string" && noun.length > 0 && !noun.includes(token)) &&
      pins.length > 0 && pins.every((pin) => typeof pin === "string" && SHA256_HEX.test(pin));
  } catch {
    return false;
  }
}

/** Own enumerable data properties only, on a plain object (Object.prototype or
 * null prototype) or a dense Array. Accessors, symbols, hidden or inherited
 * keys, holes and class instances are not JSON data. */
function jsonContainer(value: object): boolean {
  const array = Array.isArray(value), proto = Object.getPrototypeOf(value);
  if (array ? proto !== Array.prototype : proto !== Object.prototype && proto !== null) return false;
  if (Object.getOwnPropertySymbols(value).length > 0) return false;
  for (const name of Object.getOwnPropertyNames(value)) {
    if (array && name === "length") continue;
    const property = Object.getOwnPropertyDescriptor(value, name);
    if (!property || !property.enumerable || !("value" in property)) return false;
  }
  if (array) {
    const items = value as unknown[];
    if (Object.keys(items).length !== items.length) return false;
    for (let i = 0; i < items.length; i++) if (!Object.hasOwn(items, i)) return false;
  }
  return true;
}

/**
 * Exact JSON-value equality that is independent of object key order, which is
 * what a Postgres jsonb round trip changes (keys come back sorted by byte
 * length, then bytewise, at every level). Objects need exactly the same own key
 * set at every level; arrays keep their order; strings, booleans, finite
 * numbers and null compare by value. Nothing else is JSON data.
 */
export function sameJsonValue(a: unknown, b: unknown): boolean {
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    if (typeof a === "number") return typeof b === "number" && Number.isFinite(a) && a === b;
    if (typeof a === "string" || typeof a === "boolean") return a === b;
    return a === null && b === null;
  }
  if (Array.isArray(a) !== Array.isArray(b) || !jsonContainer(a) || !jsonContainer(b)) return false;
  if (Array.isArray(a)) {
    const other = b as unknown[];
    return a.length === other.length && a.every((item, i) => sameJsonValue(item, other[i]));
  }
  const left = a as Record<string, unknown>, right = b as Record<string, unknown>, keys = Object.keys(left);
  return keys.length === Object.keys(right).length &&
    keys.every((key) => Object.hasOwn(right, key) && sameJsonValue(left[key], right[key]));
}

/** Exact frozen identity equality (order-insensitive, no extra or missing keys,
 * at every nesting level), so a jsonb-read job identity matches. */
export function sameKiePropertyIdentity(value: unknown): boolean {
  return kiePropertyIdentityConsistent() && sameJsonValue(value, KIE_PROPERTY_IDENTITY);
}

/** Server-owned expectation for a retained Kie 4K clip, from ACTUAL MP4 facts
 * only. A provider echo (mode/resolution/duration) is never evidence. */
export function kieProperty4KFacts(facts: { width: number; height: number; fps: number; duration_s: number }): boolean {
  if (!kiePropertyIdentityConsistent()) return false;
  const k = KIE_PROPERTY_IDENTITY, { width, height, fps, duration_s } = facts;
  if (![width, height, fps, duration_s].every(Number.isFinite)) return false;
  const frames = Math.round(duration_s * fps);
  return fps === k.output_fps && k.output_frames.includes(frames) &&
    Math.min(width, height) >= k.min_short_side_px && width * height >= k.min_pixels &&
    Math.abs(duration_s - k.seconds) <= 0.1;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/**
 * True only for the exact reviewed steady-property-v1 prompt: for some allowed
 * scene noun, putting the template token back in place of the noun's FIRST
 * occurrence yields a text that holds the token exactly once and whose SHA-256
 * is the pinned template digest (for `motion` when given, else any pinned
 * motion). A changed character anywhere, another prompt family or an unknown
 * noun or motion is false.
 */
export async function kiePropertyPromptPinned(prompt: unknown, motion?: unknown): Promise<boolean> {
  if (!kiePropertyIdentityConsistent() || typeof prompt !== "string" || prompt.length === 0) return false;
  const k = KIE_PROPERTY_IDENTITY, token = k.prompt_template_token;
  const pins: Readonly<Record<string, string>> = k.prompt_template_sha256;
  let wanted: string[];
  if (motion === undefined) wanted = Object.values(pins);
  else if (typeof motion === "string" && Object.hasOwn(pins, motion)) wanted = [pins[motion]];
  else return false;
  for (const noun of k.prompt_scene_nouns) {
    const at = prompt.indexOf(noun);
    if (at < 0) continue;
    const template = prompt.slice(0, at) + token + prompt.slice(at + noun.length);
    if (template.split(token).length !== 2) continue;
    if (wanted.includes(await sha256Hex(template))) return true;
  }
  return false;
}
