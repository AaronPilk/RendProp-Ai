import { canonical, check, hash } from "./common.ts";
import {
  CATALOG,
  catalogRefs,
  resolveStyle,
  validateCatalog,
} from "./policy.ts";
import { equal, rejects, throws } from "./test_helpers.ts";
import { REEL_MOTION_TEXT } from "../../services/supabase/functions/ai-video/motion.ts";

Deno.test("three original policies are frozen, deterministic and draft-only", async () => {
  equal(CATALOG.map((p) => p.id), [
    "clear-tour",
    "editorial-calm",
    "concise-highlights",
  ]);
  check(
    CATALOG.every((p) =>
      p.status === "draft" && Object.isFrozen(p.presentation) &&
      Object.isFrozen(p.photo_motion_rank)
    ),
    "not deeply frozen",
  );
  throws(() => (CATALOG as unknown as unknown[]).push({}));
  equal(await catalogRefs(), await catalogRefs());
  equal((await catalogRefs()).map((r) => r.sha256), [
    "1a42815b252fe509e7fece4858caf7e68e71d09f4fd8627f521a48c00d42cd0f",
    "a8f5256bd37caee886df0475ef27e626d0c5e7e7d3e1e150ce72a0c71d70c475",
    "d24d3ff4c47997e4e37842269a2edba6e08298e605797f4834ae758b49fb8893",
  ]);
  for (const ref of await catalogRefs()) {
    equal((await resolveStyle(ref)).kind, "selected");
  }
});
Deno.test("omitted style remains legacy", async () =>
  equal((await resolveStyle(null)).kind, "legacy"));
Deno.test("canonical hashes ignore object key order but not array order", async () => {
  equal(await hash({ b: 1, a: 2 }), await hash({ a: 2, b: 1 }));
  check(await hash([1, 2]) !== await hash([2, 1]), "array identity lost");
});
Deno.test("frozen complete motion text remains exact", async () => {
  equal(
    REEL_MOTION_TEXT.push_in,
    "one slow, subtle, grounded push-in with gentle natural parallax",
  );
  equal(
    await hash(REEL_MOTION_TEXT),
    "c9dca0d48bd84f1282481485283930a7eadfd4e2cd4153a68602d1fcf1c77576",
  );
});
for (
  const [name, mutate] of [
    ["version boolean", (p: Record<string, unknown>) => p.version = true],
    ["version NaN", (p: Record<string, unknown>) => p.version = NaN],
    ["version infinity", (p: Record<string, unknown>) => p.version = Infinity],
    ["version zero", (p: Record<string, unknown>) => p.version = 0],
    [
      "version oversized",
      (p: Record<string, unknown>) => p.version = 1_000_001,
    ],
    ["unknown key", (p: Record<string, unknown>) => p.provider = "not-allowed"],
    [
      "unsupported approval",
      (p: Record<string, unknown>) => p.status = "approved",
    ],
    [
      "unsupported timing",
      (p: Record<string, unknown>) => p.timing = "retime-speech",
    ],
    [
      "unknown motion",
      (p: Record<string, unknown>) => p.photo_motion_rank = ["whip-pan"],
    ],
    [
      "duplicate motion",
      (p: Record<string, unknown>) =>
        p.photo_motion_rank = ["push_in", "push_in"],
    ],
    [
      "oversized intent",
      (p: Record<string, unknown>) =>
        p.intent = { opening_three_seconds: "x".repeat(501), pacing: "x" },
    ],
    ["grading unsupported", (p: Record<string, unknown>) =>
      p.presentation = {
        transition: "cut",
        caption: "lowerThird",
        music: "none",
        grade: "luxury-lut",
      }],
  ] as const
) {
  Deno.test(`catalog rejects ${name}`, () => {
    const p = JSON.parse(canonical(CATALOG[0]));
    mutate(p);
    throws(() => validateCatalog([p]));
  });
}
for (
  const [name, value] of [
    ["empty", []],
    ["duplicate", [CATALOG[0], CATALOG[0]]],
    ["oversized", Array(65).fill(CATALOG[0])],
    ["non-array", {}],
  ] as const
) {
  Deno.test(`catalog rejects ${name}`, () =>
    throws(() => validateCatalog(value)));
}
for (
  const kind of [
    "digest",
    "unknown-id",
    "unknown-version",
    "extra-field",
  ] as const
) {
  Deno.test(`resolver rejects ${kind}`, async () => {
    const ref: Record<string, unknown> = { ...(await catalogRefs())[0] };
    if (kind === "digest") ref.sha256 = "0".repeat(64);
    if (kind === "unknown-id") ref.id = "missing";
    if (kind === "unknown-version") ref.version = 99;
    if (kind === "extra-field") ref.provider = "forbidden";
    await rejects(() => resolveStyle(ref));
  });
}
Deno.test("hostile JSON values and accessors fail without getter execution", () => {
  let executed = false;
  const getter = Object.defineProperty({}, "x", {
    enumerable: true,
    get: () => {
      executed = true;
      return 1;
    },
  });
  const cycle: Record<string, unknown> = {};
  cycle.self = cycle;
  for (
    const value of [
      undefined,
      NaN,
      Infinity,
      -0,
      1n,
      new Date(),
      getter,
      cycle,
      JSON.parse('{"__proto__":1}'),
      { x: undefined },
    ]
  ) throws(() => canonical(value));
  check(!executed, "getter was executed");
});
Deno.test("array accessors, sparse arrays and symbols fail closed", () => {
  let executed = false;
  const getter = [1];
  Object.defineProperty(getter, "0", {
    enumerable: true,
    get: () => {
      executed = true;
      return 1;
    },
  });
  const symbol = [1];
  Object.defineProperty(symbol, Symbol("extra"), { value: 1 });
  for (const value of [getter, Array(2), symbol]) {
    throws(() => canonical(value));
  }
  check(!executed, "array getter was executed");
});
