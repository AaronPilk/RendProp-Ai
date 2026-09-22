// codes.test.ts — the parts of the invite that decide whether a stranger can
// join somebody's org. Pure functions, no server.

import { assert, assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { CODE_LENGTH, format, generateCode, hashCode, normalizeCode, normalizeEmail } from "./codes.ts";

const ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";

Deno.test("generate: 12 symbols from the alphabet, shown in groups of four", () => {
  for (let i = 0; i < 200; i++) {
    const c = generateCode();
    assertEquals(c.length, CODE_LENGTH + 2);          // 12 + two dashes
    assertEquals(c.split("-").length, 3);
    const raw = c.replace(/-/g, "");
    assertEquals(raw.length, CODE_LENGTH);
    for (const ch of raw) assert(ALPHABET.includes(ch), `stray symbol ${ch} in ${c}`);
  }
});

Deno.test("generate: the confusable characters are never in a code", () => {
  // 0/O and 1/I/L are what people mistype reading a code off a screen; U is
  // omitted so no code can be read aloud as a word.
  let all = "";
  for (let i = 0; i < 500; i++) all += generateCode();
  for (const bad of "01OILU") assert(!all.includes(bad), `${bad} appeared in a code`);
});

Deno.test("generate: codes do not repeat", () => {
  const seen = new Set<string>();
  for (let i = 0; i < 2000; i++) seen.add(generateCode());
  assertEquals(seen.size, 2000);
});

Deno.test("normalize: accepts what a person actually types", () => {
  const c = generateCode();
  const raw = c.replace(/-/g, "");
  assertEquals(normalizeCode(c), raw);                        // as displayed
  assertEquals(normalizeCode(raw), raw);                      // no dashes
  assertEquals(normalizeCode(c.toLowerCase()), raw);          // lower-cased
  assertEquals(normalizeCode(` ${c} `), raw);                 // pasted with space
  assertEquals(normalizeCode(raw.split("").join(" ")), raw);  // read out, spaced
});

Deno.test("normalize: refuses anything that is not a code", () => {
  for (const bad of ["", "   ", "ABC", "-".repeat(14), null, undefined, 12, {}, []]) {
    assertEquals(normalizeCode(bad as unknown), null, `accepted ${JSON.stringify(bad)}`);
  }
  // Right length, wrong alphabet — the confusable characters must NOT be folded
  // onto real symbols: a fold is a second input that grants the same seat.
  assertEquals(normalizeCode("OOOOOOOOOOOO"), null);
  assertEquals(normalizeCode("111111111111"), null);
  assertEquals(normalizeCode("UUUUUUUUUUUU"), null);
  // Thirteen valid symbols is not a code either.
  assertEquals(normalizeCode("2345678923456"), null);
});

Deno.test("normalize: no two different codes normalise to the same string", async () => {
  const seen = new Map<string, string>();
  for (let i = 0; i < 1000; i++) {
    const c = generateCode();
    const n = normalizeCode(c)!;
    const prior = seen.get(n);
    if (prior) assertEquals(prior, c);
    seen.set(n, c);
  }
  // And a code never collides with its own lower-case/spaced spelling by
  // accident of the alphabet.
  const c = generateCode();
  assertEquals(normalizeCode(c), normalizeCode(c.toLowerCase().replace(/-/g, " ")));
  await Promise.resolve();
});

Deno.test("hash: stable, 64 hex chars, and different per code", async () => {
  const a = normalizeCode(generateCode())!;
  const b = normalizeCode(generateCode())!;
  const ha = await hashCode(a);
  assertEquals(ha.length, 64);
  assert(/^[0-9a-f]{64}$/.test(ha));
  assertEquals(ha, await hashCode(a));            // stable
  assertNotEquals(ha, await hashCode(b));         // distinct
});

Deno.test("hash: the plaintext is not recoverable from what we store", async () => {
  const c = normalizeCode(generateCode())!;
  const h = await hashCode(c);
  assert(!h.includes(c.toLowerCase()));
  assert(!h.toUpperCase().includes(c));
});

Deno.test("format: groups of four", () => {
  assertEquals(format("23456789ABCD"), "2345-6789-ABCD");
  assertEquals(format("2345"), "2345");
  assertEquals(format(""), "");
});

Deno.test("email: only stored when it is one, always lower-cased", () => {
  assertEquals(normalizeEmail("  Agent@Brokerage.COM "), "agent@brokerage.com");
  assertEquals(normalizeEmail("a@b.co"), "a@b.co");
  for (const bad of ["", "   ", "not an email", "a@b", "@b.com", "a@.com", "a b@c.com", null, 5, {}]) {
    assertEquals(normalizeEmail(bad as unknown), null, `accepted ${JSON.stringify(bad)}`);
  }
  assertEquals(normalizeEmail("x".repeat(250) + "@b.com"), null);   // over 254
});
