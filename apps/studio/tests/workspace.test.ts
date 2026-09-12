import { test } from "node:test";
import assert from "node:assert/strict";
import {
  scopeKey,
  readPlans,
  writePlans,
  validatePlanItem,
  calendarFile,
} from "../src/workspace";
const item = {
  id: "test-post",
  title: "A new opening",
  caption: "Line one\nLine two; event, details",
  channel: "Instagram" as const,
  date: "2026-09-15T12:30",
  createdAt: "2026-09-12T12:00:00Z",
};
test("browser drafts isolate local, identity and organization", () => {
  assert.notEqual(scopeKey(null, null), scopeKey("a", "one"));
  assert.notEqual(scopeKey("a", "one"), scopeKey("b", "one"));
  assert.notEqual(scopeKey("a", "one"), scopeKey("a", "two"));
  assert.throws(() => scopeKey("a", null));
});
test("plan persistence round-trip validates every entry", () => {
  const memory = new Map<string, string>();
  const storage = {
    getItem: (key: string) => memory.get(key) ?? null,
    setItem: (key: string, value: string) => {
      memory.set(key, value);
    },
  };
  writePlans(storage, "a", [item]);
  assert.deepEqual(readPlans(storage, "a"), [item]);
  assert.deepEqual(readPlans(storage, "b"), []);
  assert.throws(() => writePlans(storage, "a", Array(101).fill(item)));
});
test("storage failure is propagated, never fake saved", () => {
  const storage = {
    getItem: () => null,
    setItem: () => {
      throw Error("quota");
    },
  };
  assert.throws(() => writePlans(storage, "a", [item]), /quota/);
});
test("malformed or unsupported post plans are rejected", () => {
  for (const patch of [
    { title: "" },
    { channel: "madeup" },
    { caption: "x".repeat(2201) },
    { date: "tomorrow" },
    { createdAt: "NaN" },
  ])
    assert.throws(() => validatePlanItem({ ...item, ...patch }));
});
test("calendar remains a manual reminder with escaped content and unique identity", () => {
  const ics = calendarFile(item);
  assert.match(ics, /BEGIN:VCALENDAR\r\n/);
  assert.match(ics, /UID:test-post@studio.rendprop.com/);
  assert.match(ics, /Line one\\nLine two\\; event\\, details/);
  assert.match(ics.replace(/\r\n /g, ""), /has not scheduled/);
  assert.match(ics, /DTSTART:\d{8}T\d{6}Z/);
  for (const line of ics.split("\r\n"))
    assert(new TextEncoder().encode(line).length <= 75);
});
test("calendar folding does not split multibyte characters", () => {
  const ics = calendarFile({ ...item, caption: "🏠".repeat(500) });
  assert(!ics.includes("\ufffd"));
  for (const line of ics.split("\r\n"))
    assert(new TextEncoder().encode(line).length <= 75);
});
