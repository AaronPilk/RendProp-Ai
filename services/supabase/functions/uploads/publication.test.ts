import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { canonicalParts, publicationKey, sameParts } from "./publication.ts";

const attempt = "12345678-1234-4321-8123-123456789abc";
Deno.test("publication keys preserve directory, media extension and role prefixes", () => {
  for (const name of ["asset", "original-asset", "gallery-asset"]) {
    assertEquals(publicationKey(`renders/org/listing/${name}.jpg`, attempt),
      `renders/org/listing/${name}-complete-${attempt}.jpg`);
  }
});
Deno.test("publication keys refuse invalid server attempt and malformed ticket", () => {
  assertThrows(() => publicationKey("uploads/o/l/a.jpg", "../unsafe"));
  assertThrows(() => publicationKey("uploads/o/l/a", attempt));
});
Deno.test("canonical multipart manifest sorts numbers and normalizes R2 ETag quoting", () => {
  assertEquals(canonicalParts([{ number: 2, etag: "b" }, { number: 1, etag: '"a"' }], 2),
    [{ number: 1, etag: '"a"' }, { number: 2, etag: '"b"' }]);
});
Deno.test("multipart rejects missing, extra, duplicated or malformed parts without filtering", () => {
  for (const value of [null, [], [{ number: 1, etag: "a" }],
    [{ number: 1, etag: "a" }, { number: 1, etag: "b" }],
    [{ number: 1, etag: "a" }, { number: 2, etag: "" }],
    [{ number: 1, etag: "a" }, { number: 2, etag: "b" }, null],
    [{ number: "1", etag: "a" }, { number: 2, etag: "b" }]]) {
    assertThrows(() => canonicalParts(value, 2));
  }
});
Deno.test("multipart part-count bound is strict", () => {
  for (const total of [0, -1, 1.5, NaN, Infinity, 10001]) assertThrows(() => canonicalParts([], total));
});
Deno.test("different same-size content ETags are not the same frozen manifest", () => {
  assertEquals(sameParts(canonicalParts([{ number: 1, etag: "AAAA" }], 1),
    canonicalParts([{ number: 1, etag: "BBBB" }], 1)), false);
});
