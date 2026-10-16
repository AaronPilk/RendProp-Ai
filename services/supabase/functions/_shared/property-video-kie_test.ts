import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { KIE_PROPERTY_IDENTITY_SOURCE } from "./property-video-kie-identity.ts";
import {
  KIE_PROPERTY_IDENTITY,
  kieProperty4KFacts,
  kiePropertyIdentityConsistent,
  kiePropertyPromptPinned,
  sameJsonValue,
  sameKiePropertyIdentity,
} from "./property-video-kie.ts";
import { buildPhotoPreservingReelPrompt, buildPropertyCanvasReelPrompt, buildSteadyPropertyReelPrompt } from "../ai-video/reel-framing.ts";
import { buildReelPrompt } from "../ai-video/motion.ts";

Deno.test("runtime Kie identity equals the canonical JSON the SQL proof compares", async () => {
  const canonical = JSON.parse(await Deno.readTextFile(new URL("./property-video-kie-identity.json", import.meta.url)));
  assertEquals(KIE_PROPERTY_IDENTITY_SOURCE, canonical);
  assertEquals({ ...KIE_PROPERTY_IDENTITY, output_frames: [...KIE_PROPERTY_IDENTITY.output_frames] }, canonical);
  // Control: one changed cent is a different identity.
  assert(!sameKiePropertyIdentity({ ...canonical, unit_cents: 33.6 }));
  assert(!sameKiePropertyIdentity({ ...canonical, extra: true }));
  assert(sameKiePropertyIdentity(canonical));
});

Deno.test("priced basis is internally exact: 67 credits/s x $0.005 x 5 s = 167.5 cents", () => {
  assertEquals(KIE_PROPERTY_IDENTITY.credits_per_second * KIE_PROPERTY_IDENTITY.usd_per_credit * 100, 33.5);
  assertEquals(KIE_PROPERTY_IDENTITY.unit_cents * KIE_PROPERTY_IDENTITY.seconds, KIE_PROPERTY_IDENTITY.attempt_cents);
  assertEquals(KIE_PROPERTY_IDENTITY.attempt_cents * KIE_PROPERTY_IDENTITY.max_paid_attempts_per_source, 335);
  assert(kiePropertyIdentityConsistent(), "the shipped identity is internally consistent");
});

Deno.test("actual-fact expectation: native 4K at 24 fps passes; Pro, 30 fps and short clips fail", () => {
  assert(kieProperty4KFacts({ width: 2492, height: 3324, fps: 24, duration_s: 121 / 24 }));
  assert(kieProperty4KFacts({ width: 3840, height: 2160, fps: 24, duration_s: 5 }));
  for (const facts of [
    { width: 1244, height: 1660, fps: 24, duration_s: 121 / 24 },
    { width: 1920, height: 1080, fps: 24, duration_s: 5 },
    { width: 2492, height: 3324, fps: 30, duration_s: 5 },
    { width: 2492, height: 3324, fps: 24, duration_s: 100 / 24 },
    { width: Number.NaN, height: 3324, fps: 24, duration_s: 5 },
  ]) assert(!kieProperty4KFacts(facts), JSON.stringify(facts));
});

// ── Compiled variants of the actual module (defect controls) ────────────────

const KIE_URL = new URL("./property-video-kie.ts", import.meta.url);
const KIE_SOURCE = await Deno.readTextFile(KIE_URL);
const IDENTITY_SOURCE = await Deno.readTextFile(new URL("./property-video-kie-identity.ts", import.meta.url));
type KieModule = typeof import("./property-video-kie.ts");

function dataUrl(source: string): string {
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return `data:application/typescript;base64,${btoa(binary)}`;
}
/** Exactly one occurrence of `needle`, replaced (a unique, actual anchor). */
function once(text: string, needle: string, replacement: string): string {
  assertEquals(text.split(needle).length, 2, `Anchor must occur exactly once: ${needle}`);
  return text.replace(needle, () => replacement);
}
/** property-video-kie.ts (optionally mutated) over the real or a mutated identity module. */
async function compileKie(source = KIE_SOURCE, identity?: string): Promise<KieModule> {
  const text = source.replace(/from "(\.\/[^"]+)"/g, (_all, path: string) =>
    `from ${JSON.stringify(path === "./property-video-kie-identity.ts" && identity !== undefined ? dataUrl(identity) : new URL(path, KIE_URL).href)}`);
  return await import(dataUrl(text));
}

/** Postgres jsonb object key order: UTF-8 byte length, then bytewise, at every level. */
function byteOrder(a: string, b: string): number {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return x.length - y.length;
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}
// deno-lint-ignore no-explicit-any
function reorder(value: unknown, order: (keys: string[]) => string[]): any {
  if (Array.isArray(value)) return value.map((item) => reorder(item, order));
  if (value && typeof value === "object") {
    return Object.fromEntries(order(Object.keys(value)).map((key) => [key, reorder((value as Record<string, unknown>)[key], order)]));
  }
  return value;
}
const jsonbOrder = (value: unknown) => reorder(value, (keys) => [...keys].sort(byteOrder));
const reversedOrder = (value: unknown) => reorder(value, (keys) => [...keys].reverse());
const canonical = () => JSON.parse(JSON.stringify(KIE_PROPERTY_IDENTITY));
const OLD_STRINGIFY_COMPARISON = `const v = value as Record<string, unknown>, keys = Object.keys(KIE_PROPERTY_IDENTITY).sort();
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(v).sort().join(",") !== keys.join(",")) return false;
  return keys.every((key) => JSON.stringify(v[key]) === JSON.stringify((KIE_PROPERTY_IDENTITY as Record<string, unknown>)[key]));`;
const COMPARISON = "return kiePropertyIdentityConsistent() && sameJsonValue(value, KIE_PROPERTY_IDENTITY);";

// ── 1. Deep freeze ───────────────────────────────────────────────────────────

function everyLevelFrozen(value: unknown, path = "identity"): string[] {
  if (!value || typeof value !== "object") return [];
  return [...(Object.isFrozen(value) ? [] : [path]),
    ...Object.entries(value).flatMap(([key, item]) => everyLevelFrozen(item, `${path}.${key}`))];
}

Deno.test("KIE_PROPERTY_IDENTITY is deep-frozen (nested arrays and objects too) and independent of the source object", async () => {
  assertEquals(everyLevelFrozen(KIE_PROPERTY_IDENTITY), []);
  assert(KIE_PROPERTY_IDENTITY !== KIE_PROPERTY_IDENTITY_SOURCE);
  for (const key of ["output_frames", "prompt_scene_nouns", "prompt_template_sha256"] as const) {
    assert((KIE_PROPERTY_IDENTITY[key] as unknown) !== (KIE_PROPERTY_IDENTITY_SOURCE[key] as unknown), `${key} is a copy`);
  }
  const identity = KIE_PROPERTY_IDENTITY as unknown as Record<string, unknown> & {
    output_frames: number[]; prompt_scene_nouns: string[]; prompt_template_sha256: Record<string, string>;
  };
  assertThrows(() => { identity.unit_cents = 1; }, TypeError);
  assertThrows(() => { identity.output_frames.push(122); }, TypeError);
  assertThrows(() => { identity.prompt_scene_nouns[0] = "castle"; }, TypeError);
  assertThrows(() => { identity.prompt_template_sha256.push_in = "0".repeat(64); }, TypeError);
  assertThrows(() => { delete identity.prompt_template_sha256.fly_through; }, TypeError);
  // A later mutation of the exported source object never reaches the frozen identity.
  const saved = KIE_PROPERTY_IDENTITY_SOURCE.prompt_scene_nouns[0];
  try {
    KIE_PROPERTY_IDENTITY_SOURCE.prompt_scene_nouns[0] = "castle";
    assertEquals(KIE_PROPERTY_IDENTITY.prompt_scene_nouns[0], "home");
  } finally {
    KIE_PROPERTY_IDENTITY_SOURCE.prompt_scene_nouns[0] = saved;
  }
  // Defect control: the pre-fix shallow freeze leaves the nested prompt pin mutable.
  const shallow = await compileKie(once(KIE_SOURCE, "export const KIE_PROPERTY_IDENTITY = deepFrozenCopy(source);",
    "export const KIE_PROPERTY_IDENTITY = Object.freeze({ ...source, output_frames: Object.freeze([...source.output_frames]) }) as unknown as DeepReadonly<typeof source>;"));
  assertEquals(everyLevelFrozen(shallow.KIE_PROPERTY_IDENTITY), ["identity.prompt_scene_nouns", "identity.prompt_template_sha256"],
    "control: the shallow freeze exposes mutable nested pins");
});

// ── 2. jsonb key order ───────────────────────────────────────────────────────

Deno.test("identity equality ignores jsonb key order at every level; a pre-fix stringify comparison refused every DB read", async () => {
  const jsonb = jsonbOrder(canonical());
  assertEquals(Object.keys(jsonb.prompt_template_sha256), ["push_in", "pull_back", "side_glide", "fly_through"], "true jsonb order (by byte length)");
  assertEquals(JSON.stringify(jsonbOrder({ kie_mode: "4K", sound: false })), '{"sound":false,"kie_mode":"4K"}');
  assert(JSON.stringify(jsonb) !== JSON.stringify(canonical()), "the fixture really is reordered");
  for (const [label, value] of [["canonical", canonical()], ["jsonb", jsonb], ["reversed", reversedOrder(canonical())],
    ["jsonb of reversed", jsonbOrder(reversedOrder(canonical()))], ["null-prototype plain data", Object.assign(Object.create(null), jsonb)]] as const) {
    assert(sameKiePropertyIdentity(value), label);
  }
  // Defect control: the pre-fix comparison (nested values through JSON.stringify).
  const old = await compileKie(once(KIE_SOURCE, COMPARISON, OLD_STRINGIFY_COMPARISON));
  assert(old.sameKiePropertyIdentity(canonical()), "control: the old comparison only accepted the canonical order");
  assert(!old.sameKiePropertyIdentity(jsonb), "control: the old comparison refused the identity PostgREST returns");
  assert(!old.sameKiePropertyIdentity(reversedOrder(canonical())), "control: and any other order");
});

Deno.test("nested and top-level drift, non-JSON values and prototype tricks are refused in either key order", () => {
  for (const base of [jsonbOrder(canonical()), reversedOrder(canonical())]) {
    const pins = { ...base.prompt_template_sha256 }, { push_in: _missing, ...withoutPushIn } = pins, { route_id: _route, ...withoutRoute } = base;
    const flipped = pins.fly_through.slice(0, -1) + (pins.fly_through.endsWith("0") ? "1" : "0");
    const drifts: [string, unknown][] = [
      ["extra nested key", { ...base, prompt_template_sha256: { ...pins, orbit: "0".repeat(64) } }],
      ["missing nested key", { ...base, prompt_template_sha256: withoutPushIn }],
      ["changed digest character", { ...base, prompt_template_sha256: { ...pins, fly_through: flipped } }],
      ["nested null", { ...base, prompt_template_sha256: { ...pins, push_in: null } }],
      ["nested object as array", { ...base, prompt_template_sha256: Object.values(pins) }],
      ["output_frames order", { ...base, output_frames: [121, 120] }],
      ["noun order", { ...base, prompt_scene_nouns: [...base.prompt_scene_nouns].reverse() }],
      ["extra noun", { ...base, prompt_scene_nouns: [...base.prompt_scene_nouns, "castle"] }],
      ["missing noun", { ...base, prompt_scene_nouns: base.prompt_scene_nouns.slice(1) }],
      ["number as string", { ...base, unit_cents: "33.5" }],
      ["boolean as string", { ...base, sound: "false" }],
      ["NaN", { ...base, unit_cents: Number.NaN }],
      ["Infinity", { ...base, min_pixels: Number.POSITIVE_INFINITY }],
      ["undefined value", { ...base, mode: undefined }],
      ["extra top-level key", { ...base, extra: true }],
      ["missing top-level key", withoutRoute],
      ["JSON text", JSON.stringify(base)], ["array", [base]], ["null", null], ["undefined", undefined],
      ["__proto__ own key", JSON.parse(JSON.stringify(base).replace(/^\{/, '{"__proto__":{},'))],
    ];
    for (const [label, value] of drifts) assert(!sameKiePropertyIdentity(value), label);
    class Lookalike { constructor() { Object.assign(this, base); } }
    const accessor = { ...base };
    Object.defineProperty(accessor, "unit_cents", { get: () => 33.5, enumerable: true });
    const hidden = { ...base };
    Object.defineProperty(hidden, "hidden", { value: 1, enumerable: false });
    const holes = new Array(2) as number[];
    holes[1] = 121;
    const arrayExtra = Object.assign([120, 121], { extra: 1 });
    const tricks: [string, unknown][] = [
      ["inherited keys", Object.create(base)], ["class instance", new Lookalike()], ["accessor property", accessor],
      ["hidden property", hidden], ["symbol key", { ...base, [Symbol("x")]: 1 }],
      ["sparse array", { ...base, output_frames: holes }], ["array with an extra property", { ...base, output_frames: arrayExtra }],
    ];
    for (const [label, value] of tricks) assert(!sameKiePropertyIdentity(value), label);
  }
  assert(sameJsonValue({ a: [1, { b: null, c: "x" }] }, { a: [1, { c: "x", b: null }] }));
  assert(!sameJsonValue({ a: [1, 2] }, { a: [2, 1] }));
  assert(!sameJsonValue(-0, "0") && sameJsonValue(-0, 0) && !sameJsonValue(Number.NaN, Number.NaN));
});

// ── 3. Actual-fact acceptance ────────────────────────────────────────────────

const PASSING_FACTS: [string, { width: number; height: number; fps: number; duration_s: number }][] = [
  // A FAL-derived 4K geometry fixture: no retained Kie MP4 exists, so these are not Kie output facts.
  ["FAL-derived 4K geometry fixture 2492x3324, 121 frames", { width: 2492, height: 3324, fps: 24, duration_s: 121 / 24 }],
  ["UHD 3840x2160, 120 frames", { width: 3840, height: 2160, fps: 24, duration_s: 5 }],
  ["UHD 3840x2160, 121 frames", { width: 3840, height: 2160, fps: 24, duration_s: 121 / 24 }],
  ["portrait UHD 2160x3840, 120 frames", { width: 2160, height: 3840, fps: 24, duration_s: 5 }],
  ["portrait UHD 2160x3840, 121 frames", { width: 2160, height: 3840, fps: 24, duration_s: 121 / 24 }],
  ["short side exactly2160 just above8MP; not an exactUHD canvas rule", { width: 2160, height: 3704, fps: 24, duration_s: 5 }],
];
const FAILING_FACTS: [string, { width: number; height: number; fps: number; duration_s: number }][] = [
  ["wide source-auto 4068x2032 below2160", { width: 4068, height: 2032, fps: 24, duration_s: 5 }],
  ["tall source-auto 1952x4236 below2160", { width: 1952, height: 4236, fps: 24, duration_s: 121 / 24 }],
  ["short side1080 with8MP", { width: 1080, height: 7408, fps: 24, duration_s: 5 }],
  ["wide8192x1080 exceeds8MP but short side1080", { width: 8192, height: 1080, fps: 24, duration_s: 5 }],
  ["tall1080x8192 exceeds8MP but short side1080", { width: 1080, height: 8192, fps: 24, duration_s: 5 }],
  ["2159x4000 below2160 despite8MP", { width: 2159, height: 4000, fps: 24, duration_s: 5 }],
  ["2160x3600 shortside valid but below8MP", { width: 2160, height: 3600, fps: 24, duration_s: 5 }],
  ["Pro-class 1244x1660", { width: 1244, height: 1660, fps: 24, duration_s: 121 / 24 }],
  ["1920x1080", { width: 1920, height: 1080, fps: 24, duration_s: 5 }],
  ["2800x2800 (7.84 MP)", { width: 2800, height: 2800, fps: 24, duration_s: 5 }],
  ["8100x1000 (short side under 1080)", { width: 8100, height: 1000, fps: 24, duration_s: 5 }],
  ["30 fps", { width: 2492, height: 3324, fps: 30, duration_s: 5 }],
  ["23.976 fps", { width: 2492, height: 3324, fps: 23.976, duration_s: 5 }],
  ["100 frames", { width: 2492, height: 3324, fps: 24, duration_s: 100 / 24 }],
  ["122 frames", { width: 2492, height: 3324, fps: 24, duration_s: 122 / 24 }],
  ["NaN width", { width: Number.NaN, height: 3324, fps: 24, duration_s: 5 }],
  ["Infinity height", { width: 2492, height: Number.POSITIVE_INFINITY, fps: 24, duration_s: 5 }],
  ["Infinity duration", { width: 2492, height: 3324, fps: 24, duration_s: Number.POSITIVE_INFINITY }],
];
function factsOracle(kie: KieModule): void {
  assertEquals([kie.KIE_PROPERTY_IDENTITY.min_short_side_px, kie.KIE_PROPERTY_IDENTITY.min_pixels], [2160, 8_000_000]);
  for (const [label, facts] of PASSING_FACTS) assert(kie.kieProperty4KFacts(facts), `FACTS pass: ${label}`);
  for (const [label, facts] of FAILING_FACTS) assert(!kie.kieProperty4KFacts(facts), `FACTS fail: ${label}`);
}

Deno.test("actual-fact acceptance is the identity's rule: short side >= 2160, >= 8 MP, CFR 24, 120/121 frames, 5 +/- 0.1 s", async () => {
  factsOracle(await compileKie());
  for (const [needle, replacement, label] of [
    ["Math.min(width, height) >= k.min_short_side_px && ", "", "short side"],
    [" && width * height >= k.min_pixels", "", "pixel count"],
    ["fps === k.output_fps && ", "", "cadence"],
    ["k.output_frames.includes(frames) &&", "", "frame count"],
    ["if (![width, height, fps, duration_s].every(Number.isFinite)) return false;", "", "finite facts"],
  ]) {
    const broken = await compileKie(once(KIE_SOURCE, needle, replacement));
    assertThrows(() => factsOracle(broken), Error, "FACTS fail", `control: ${label} guard removed is detected`);
  }
});

// ── 4. Prompt pin ────────────────────────────────────────────────────────────

const MOTIONS = ["fly_through", "push_in", "side_glide", "pull_back"] as const;
const ASPECTS = ["16:9", "9:16"] as const;
async function promptOracle(kie: KieModule): Promise<void> {
  for (const noun of kie.KIE_PROPERTY_IDENTITY.prompt_scene_nouns) for (const motion of MOTIONS) for (const aspect of ASPECTS) {
    const prompt = buildSteadyPropertyReelPrompt(noun, motion, aspect);
    assert(await kie.kiePropertyPromptPinned(prompt, motion), `PIN pass: ${noun} ${motion} ${aspect}`);
    assert(await kie.kiePropertyPromptPinned(prompt), `PIN pass (any motion): ${noun} ${motion} ${aspect}`);
    for (const other of MOTIONS.filter((m) => m !== motion)) assert(!await kie.kiePropertyPromptPinned(prompt, other), `PIN wrong motion: ${motion} as ${other}`);
  }
  const prompt = buildSteadyPropertyReelPrompt("home", "push_in", "16:9");
  const at = (i: number) => prompt.slice(0, i) + (prompt[i] === "x" ? "y" : "x") + prompt.slice(i + 1);
  const refused: [string, unknown, unknown?][] = [
    ["first character changed", at(0)], ["middle character changed", at(Math.floor(prompt.length / 2))], ["last character changed", at(prompt.length - 1)],
    ["one extra space", prompt.replace("slider take", "slider  take")], ["trailing newline", prompt + "\n"], ["leading space", " " + prompt],
    ["unknown noun", buildSteadyPropertyReelPrompt("castle", "push_in", "16:9")], ["plural noun", buildSteadyPropertyReelPrompt("homes", "push_in", "16:9")],
    ["template token itself", buildSteadyPropertyReelPrompt("{scene_noun}", "push_in", "16:9")],
    ["token injected", prompt + " {scene_noun}"],
    ["FAL v1 canvas prompt", buildPropertyCanvasReelPrompt("home", "push_in", "16:9")],
    ["photo-preserving prompt", buildPhotoPreservingReelPrompt("home", "push_in")],
    ["legacy reel prompt", buildReelPrompt({ sceneNoun: "home", motion: "push_in" })],
    ["unknown motion", prompt, "orbit"], ["inherited motion key", prompt, "toString"], ["non-string motion", prompt, 1],
    ["empty", ""], ["non-string", 42], ["null", null],
  ];
  for (const [label, value, motion] of refused) {
    assert(!await kie.kiePropertyPromptPinned(value, ...(motion === undefined ? [] : [motion])), `PIN refuse: ${label}`);
  }
}

Deno.test("prompt pin: all 4 motions x 6 nouns x 2 canvases pass; any changed character, other family, noun or motion fails", async () => {
  await promptOracle(await compileKie());
  // The 'space' noun also occurs later inside "spaces": only its FIRST occurrence is the interpolated one.
  assert(await kiePropertyPromptPinned(buildSteadyPropertyReelPrompt("space", "side_glide", "9:16"), "side_glide"));
  for (const [needle, replacement, label] of [
    ["if (wanted.includes(await sha256Hex(template))) return true;", "return true;", "digest comparison"],
    ["else if (typeof motion === \"string\" && Object.hasOwn(pins, motion)) wanted = [pins[motion]];", "else if (typeof motion === \"string\") wanted = Object.values(pins);", "motion scoping"],
    ["const at = prompt.indexOf(noun);", "const at = prompt.lastIndexOf(noun);", "first occurrence"],
  ]) {
    const broken = await compileKie(once(KIE_SOURCE, needle, replacement));
    await assertRejects(() => promptOracle(broken), Error, "PIN", `control: ${label} removed is detected`);
  }
});

// ── 5. Lazy consistency: never a module-load crash, every Kie path refuses ──

const BROKEN_IDENTITIES: [string, string, string][] = [
  ["profile renamed", '"profile": "kie-kling3-4k-steady-v1",', '"profile": "kie-kling3-4k-steady-v2",'],
  ["unit cents", '"unit_cents": 33.5,', '"unit_cents": 33.6,'],
  ["attempt cents", '"attempt_cents": 167.5,', '"attempt_cents": 168,'],
  ["credits per second", '"credits_per_second": 67,', '"credits_per_second": 68,'],
  ["usd per credit", '"usd_per_credit": 0.005,', '"usd_per_credit": 0.006,'],
  ["frame budget", '"output_frames": [\n    120,\n    121\n  ],', '"output_frames": [\n    121,\n    122\n  ],'],
  ["fps", '"output_fps": 24,', '"output_fps": 0,'],
  ["short side floor", '"min_short_side_px": 2160,', '"min_short_side_px": 0,'],
  ["pixel floor", '"min_pixels": 8000000,', '"min_pixels": -1,'],
  ["empty token", '"prompt_template_token": "{scene_noun}",', '"prompt_template_token": "",'],
  ["duplicate noun", '"store",', '"home",'],
  ["noun holding the token", '"space"\n', '"{scene_noun} space"\n'],
  ["non-hex digest", '"fly_through": "5a27f080', '"fly_through": "5A27F080'],
  ["short digest", '"push_in": "275836a1', '"push_in": "275836a'],
];

async function brokenModules(): Promise<[string, KieModule][]> {
  const out: [string, KieModule][] = [];
  for (const [label, needle, replacement] of BROKEN_IDENTITIES) out.push([label, await compileKie(KIE_SOURCE, once(IDENTITY_SOURCE, needle, replacement))]);
  return out;
}

async function refusesEverywhere(label: string, kie: KieModule): Promise<void> {
  const k = kie.KIE_PROPERTY_IDENTITY;
  assert(!kie.kiePropertyIdentityConsistent(), `LAZY ${label}: inconsistent`);
  assert(!kie.sameKiePropertyIdentity(JSON.parse(JSON.stringify(k))), `LAZY ${label}: no job identity matches`);
  assert(!kie.kieProperty4KFacts({ width: 2492, height: 3324, fps: 24, duration_s: 5 }), `LAZY ${label}: no clip is accepted`);
  assert(!await kie.kiePropertyPromptPinned(buildSteadyPropertyReelPrompt("home", "push_in", "9:16"), "push_in"), `LAZY ${label}: no prompt is pinned`);
}

Deno.test("an inconsistent identity never throws at module load; every Kie helper refuses instead", async () => {
  for (const [label, kie] of await brokenModules()) await refusesEverywhere(label, kie);
  // Defect controls: each lazy check removed lets the broken identity through.
  const identity = once(IDENTITY_SOURCE, '"unit_cents": 33.5,', '"unit_cents": 33.6,');
  for (const [needle, replacement, label] of [
    [COMPARISON, "return sameJsonValue(value, KIE_PROPERTY_IDENTITY);", "identity comparison"],
    ["  if (!kiePropertyIdentityConsistent()) return false;\n  const k = KIE_PROPERTY_IDENTITY, { width,", "  const k = KIE_PROPERTY_IDENTITY, { width,", "facts"],
    ["if (!kiePropertyIdentityConsistent() || typeof prompt !== \"string\"", "if (typeof prompt !== \"string\"", "prompt pin"],
  ]) {
    const broken = await compileKie(once(KIE_SOURCE, needle, replacement), identity);
    await assertRejects(() => refusesEverywhere(label, broken), Error, "LAZY", `control: ${label} without the lazy check accepts a broken identity`);
  }
  // Defect control: the pre-fix eager module-level throw crashes every importer at load.
  const eager = KIE_SOURCE + '\nif (!kiePropertyIdentityConsistent()) throw new Error("Kie property identity is internally inconsistent");\n';
  await assertRejects(() => compileKie(eager, identity), Error, "internally inconsistent");
  assert((await compileKie(eager)).kiePropertyIdentityConsistent(), "the shipped identity loads even with an eager check");
});

Deno.test("owner-required native2160 rejects1080-side8MPpanoramas", () => {
  for (const [width, height] of [[8192,1080],[1080,8192]]) {
    assertEquals(kieProperty4KFacts({width,height,fps:24,duration_s:5}), false,
      `Actual ${width}x${height} has enough area but fails the owner-required2160 short side`);
  }
});
