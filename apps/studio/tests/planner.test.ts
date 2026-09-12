import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bindPlanDate,
  calendarFile,
  filterPlans,
  planDateChoices,
  plannerWeekStart,
  readPlans,
  removePlan,
  savePlan,
  shiftPlannerWeek,
  validatePlanItem,
  validatePlans,
  writePlans,
} from "../src/workspace";
import type { PlanItem } from "../src/workspace";

const legacy: PlanItem = {
  id: "test-post",
  title: "Open house",
  caption: "Meet the space.",
  channel: "Instagram",
  date: "2026-09-15T12:30",
  createdAt: "2026-09-12T12:00:00Z",
};
const bound: PlanItem = {
  ...legacy,
  ...bindPlanDate(legacy.date, "America/New_York"),
};
const fixture = (
  id: string,
  date: string,
  timeZone = "America/New_York",
): PlanItem => ({ ...legacy, id, ...bindPlanDate(date, timeZone) });

for (const date of [
  "2026-02-30T12:30",
  "2025-02-29T12:30",
  "2026-04-31T12:30",
  "2026-13-01T12:30",
  "2026-00-01T12:30",
  "2026-01-00T12:30",
  "2026-09-15T24:00",
  "2026-09-15T12:60",
  "2026-9-15T12:30",
  "2026-09-15T12:30Z",
]) {
  test(`real calendar rejects ${date}`, () =>
    assert.throws(() => validatePlanItem({ ...legacy, date })));
}
test("negative control: old Date.parse guard accepts February 30; actual validator refuses it", () => {
  assert(Number.isFinite(Date.parse("2026-02-30T12:30")));
  assert.throws(
    () => validatePlanItem({ ...legacy, date: "2026-02-30T12:30" }),
    /real calendar/,
  );
  assert.equal(
    validatePlanItem({ ...legacy, date: "2028-02-29T12:30" }).date,
    "2028-02-29T12:30",
  );
});
test("new plans bind summer and winter offsets independently", () => {
  assert.equal(bound.scheduledAt, "2026-09-15T16:30:00.000Z");
  assert.equal(
    bindPlanDate("2026-12-15T12:30", "America/New_York").scheduledAt,
    "2026-12-15T17:30:00.000Z",
  );
});
test("spring-forward gap is not silently shifted into a later hour", () => {
  assert.deepEqual(planDateChoices("2026-03-08T02:30", "America/New_York"), []);
  assert.throws(
    () => bindPlanDate("2026-03-08T02:30", "America/New_York"),
    /does not exist/,
  );
  assert.equal(
    bindPlanDate("2026-03-08T03:30", "America/New_York").scheduledAt,
    "2026-03-08T07:30:00.000Z",
  );
});
test("fall-back repeated hour requires explicit first or second occurrence", () => {
  const choices = planDateChoices("2026-11-01T01:30", "America/New_York");
  assert.deepEqual(choices, [
    "2026-11-01T05:30:00.000Z",
    "2026-11-01T06:30:00.000Z",
  ]);
  assert.throws(
    () => bindPlanDate("2026-11-01T01:30", "America/New_York"),
    /occurs twice/,
  );
  for (const scheduledAt of choices)
    assert.equal(
      validatePlanItem({
        ...legacy,
        ...bindPlanDate("2026-11-01T01:30", "America/New_York", scheduledAt),
      }).scheduledAt,
      scheduledAt,
    );
});
test("changed date rejects an old DST occurrence selection", () => {
  assert.throws(
    () =>
      bindPlanDate(
        "2026-11-02T01:30",
        "America/New_York",
        "2026-11-01T05:30:00.000Z",
      ),
    /no longer matches/,
  );
});
test("half-hour DST transition works without assuming a one-hour change", () => {
  const choices = planDateChoices("2026-04-05T01:45", "Australia/Lord_Howe");
  assert.equal(choices.length, 2);
  assert.equal(Date.parse(choices[1]) - Date.parse(choices[0]), 30 * 60_000);
  assert.deepEqual(
    planDateChoices("2026-10-04T02:15", "Australia/Lord_Howe"),
    [],
  );
});
test("quarter-hour zone and whole skipped calendar day are handled", () => {
  assert.equal(
    bindPlanDate("2026-09-15T12:30", "Asia/Kathmandu").scheduledAt,
    "2026-09-15T06:45:00.000Z",
  );
  assert.deepEqual(planDateChoices("2011-12-30T12:30", "Pacific/Apia"), []);
});
test("unknown, oversized and non-zone identifiers fail", () => {
  for (const zone of ["Mars/Olympus", "a".repeat(101), "UTC\r\nX-EVIL:yes", ""])
    assert.throws(() => bindPlanDate(legacy.date, zone), /timezone/);
});
test("bound reminder fields must exist together and match real wall time", () => {
  for (const patch of [
    { timeZone: "UTC" },
    { scheduledAt: bound.scheduledAt },
    { timeZone: "UTC", scheduledAt: bound.scheduledAt },
    { timeZone: "America/New_York", scheduledAt: "2026-09-15T16:30:01.000Z" },
    { timeZone: "America/New_York", scheduledAt: "2026-09-15T16:30:00.001Z" },
  ])
    assert.throws(() => validatePlanItem({ ...legacy, ...patch }));
});
test("accepted UTC spellings canonicalize to the exact date-choice identity for editing", () => {
  const normalized = validatePlanItem({
    ...bound,
    scheduledAt: "2026-09-15T16:30:00Z",
  });
  assert.equal(normalized.scheduledAt, "2026-09-15T16:30:00.000Z");
  assert.equal(
    bindPlanDate(normalized.date, normalized.timeZone!, normalized.scheduledAt)
      .scheduledAt,
    normalized.scheduledAt,
  );
});
test("created timestamps must be real UTC instants, not normalized or timezone-less values", () => {
  for (const createdAt of [
    "2026-02-30T12:00:00Z",
    "2026-09-12T24:00:00Z",
    "2026-09-12T12:00:60Z",
    "2026-09-12T12:00:00",
    "September 12 2026",
  ])
    assert.throws(() => validatePlanItem({ ...legacy, createdAt }));
});
test("strict IDs preserve legacy test-post and UUID but reject calendar UID injection", () => {
  for (const id of [
    "",
    "has space",
    "x\rATTENDEE:bad",
    "x\nBEGIN:VEVENT",
    "x:y",
    "x;z",
    "x".repeat(101),
  ])
    assert.throws(
      () => validatePlanItem({ ...legacy, id }),
      /identity|Invalid content/,
    );
  assert.equal(
    validatePlanItem({ ...legacy, id: "db7288aa-3d17-43e5-aefe-471346e42fd6" })
      .id,
    "db7288aa-3d17-43e5-aefe-471346e42fd6",
  );
  assert.deepEqual(validatePlanItem(legacy), legacy);
});
test("validation strips unknown fields rather than persisting arbitrary payloads", () => {
  assert.deepEqual(
    validatePlanItem({ ...bound, unexpected: { large: "data" } }),
    bound,
  );
  assert.throws(() => validatePlanItem([]));
});
test("new item is appended immutably and duplicates are never created", () => {
  const items = Object.freeze([Object.freeze(bound)]) as unknown as PlanItem[];
  const next = savePlan(items, fixture("second", "2026-09-16T12:30"));
  assert.equal(next.length, 2);
  assert.equal(items.length, 1);
  assert.deepEqual(next[0], bound);
  assert.throws(() => savePlan(items, bound), /duplicate/);
});
test("editing preserves identity, creation date and all other plans", () => {
  const other = fixture("second", "2026-09-16T12:30");
  const changed = {
    ...bound,
    title: "Updated open house",
    caption: "Changed caption",
    channel: "YouTube" as const,
  };
  const next = savePlan([bound, other], changed, bound.id);
  assert.deepEqual(next, [changed, other]);
  assert.equal(next.length, 2);
  assert.equal(bound.title, "Open house");
});
test("a stale or identity-changing edit never creates a new entry", () => {
  assert.throws(() => savePlan([], bound, bound.id), /changed or was removed/);
  assert.throws(
    () => savePlan([bound], { ...bound, id: "replacement" }, bound.id),
    /changed or was removed/,
  );
  assert.throws(
    () =>
      savePlan(
        [bound],
        { ...bound, createdAt: "2026-09-13T12:00:00Z" },
        bound.id,
      ),
    /changed or was removed/,
  );
});
test("at 100 entries edits/removals work but new entry 101 does not", () => {
  const full = Array.from({ length: 100 }, (_, i) => ({
    ...bound,
    id: `plan-${i}`,
  }));
  assert.equal(validatePlans(full).length, 100);
  assert.throws(() => savePlan(full, { ...bound, id: "overflow" }), /100/);
  assert.equal(
    savePlan(full, { ...full[99], title: "Last updated" }, full[99].id)[99]
      .title,
    "Last updated",
  );
  const removed = removePlan(full, "plan-50");
  assert.equal(removed.length, 99);
  assert.equal(full.length, 100);
  assert(!removed.some((p) => p.id === "plan-50"));
  assert.equal(savePlan(removed, { ...bound, id: "replacement" }).length, 100);
  assert.throws(() => removePlan(full, "missing"), /already been removed/);
});
test("duplicate saved IDs fail both read and write, without partial storage", () => {
  let writes = 0;
  const storage = {
    getItem: () => JSON.stringify([bound, bound]),
    setItem: () => {
      writes++;
    },
  };
  assert.throws(() => readPlans(storage, "local"), /duplicate/);
  assert.throws(
    () => writePlans(storage, "local", [bound, bound]),
    /duplicate/,
  );
  assert.equal(writes, 0);
});
test("failed edit/remove persistence propagates before callers may claim success", () => {
  const storage = {
    getItem: () => null,
    setItem: () => {
      throw Error("quota denied");
    },
  };
  assert.throws(
    () =>
      writePlans(
        storage,
        "local",
        savePlan([bound], { ...bound, title: "Changed" }, bound.id),
      ),
    /quota denied/,
  );
  assert.throws(
    () => writePlans(storage, "local", removePlan([bound], bound.id)),
    /quota denied/,
  );
});
test("calendar escapes lone CR, CRLF, LF, backslash, comma and semicolon", () => {
  const ics = calendarFile({
    ...bound,
    title: "Plan\rBEGIN:VEVENT",
    caption: "a\rb\r\nc\nd\\e;f,g",
  }).replace(/\r\n /g, "");
  assert.match(ics, /SUMMARY:Instagram: Plan\\nBEGIN:VEVENT\r\n/);
  assert.match(ics, /a\\nb\\nc\\nd\\\\e\\;f\\,g/);
  assert.equal(
    ics.split("\r\n").filter((line) => line === "BEGIN:VEVENT").length,
    1,
  );
  assert(!ics.replace(/\r\n/g, "").includes("\r"));
});
test("bound ICS is unchanged if the browser/host timezone changes later", () => {
  const previous = process.env.TZ;
  try {
    process.env.TZ = "America/New_York";
    const initial = calendarFile(bound);
    process.env.TZ = "Asia/Tokyo";
    assert.equal(calendarFile(bound), initial);
    assert.match(initial, /DTSTART:20260915T163000Z/);
    assert.match(initial, /DTEND:20260915T164500Z/);
  } finally {
    if (previous === undefined) delete process.env.TZ;
    else process.env.TZ = previous;
  }
});
test("legacy normal reminder remains compatible but ambiguous or nonexistent legacy export needs an edit", () => {
  const previous = process.env.TZ;
  try {
    process.env.TZ = "America/New_York";
    assert.match(calendarFile(legacy), /DTSTART:20260915T163000Z/);
    assert.throws(
      () => calendarFile({ ...legacy, date: "2026-11-01T01:30" }),
      /occurs twice/,
    );
    assert.throws(
      () => calendarFile({ ...legacy, date: "2026-03-08T02:30" }),
      /does not exist/,
    );
  } finally {
    if (previous === undefined) delete process.env.TZ;
    else process.env.TZ = previous;
  }
});
test("calendar Monday start respects timezone and week navigation crosses year and DST boundaries", () => {
  assert.equal(
    plannerWeekStart(Date.parse("2026-09-14T01:00:00Z"), "America/New_York"),
    "2026-09-07",
  );
  assert.equal(
    plannerWeekStart(Date.parse("2026-09-14T01:00:00Z"), "Asia/Tokyo"),
    "2026-09-14",
  );
  assert.equal(shiftPlannerWeek("2026-12-28", 1), "2027-01-04");
  assert.equal(shiftPlannerWeek("2026-03-02", 1), "2026-03-09");
  assert.throws(() => shiftPlannerWeek("2026-02-30", 1));
  assert.throws(() => shiftPlannerWeek("2026-03-02", 0.5));
});
test("filter and week use browser-zone dates while cards retain the saved timezone", () => {
  const earlier = fixture("earlier", "2026-09-13T22:30"),
    monday = fixture("monday", "2026-09-14T10:00"),
    later = {
      ...fixture("later", "2026-09-21T10:00"),
      channel: "TikTok" as const,
    };
  const items = [later, monday, earlier],
    base = {
      channel: "All" as const,
      view: "week" as const,
      timeZone: "America/New_York",
      now: Date.parse("2026-09-14T00:00:00Z"),
      weekStart: "2026-09-14",
    };
  assert.deepEqual(
    filterPlans(items, base).map((p) => p.id),
    ["monday"],
  );
  assert.deepEqual(
    filterPlans(items, { ...base, timeZone: "Asia/Tokyo" }).map((p) => p.id),
    ["earlier", "monday"],
  );
  assert.deepEqual(
    filterPlans(items, { ...base, view: "all", channel: "TikTok" }).map(
      (p) => p.id,
    ),
    ["later"],
  );
  assert.deepEqual(
    items.map((p) => p.id),
    ["later", "monday", "earlier"],
  );
});
test("upcoming compares bound instants and fall-back sort keeps first occurrence first", () => {
  const date = "2026-11-01T01:30",
    choices = planDateChoices(date, "America/New_York");
  const first = {
      ...legacy,
      id: "first",
      ...bindPlanDate(date, "America/New_York", choices[0]),
    },
    second = {
      ...legacy,
      id: "second",
      ...bindPlanDate(date, "America/New_York", choices[1]),
    };
  const base = {
    channel: "All" as const,
    view: "all" as const,
    timeZone: "America/New_York",
    now: Date.parse("2026-11-01T06:00:00Z"),
    weekStart: "2026-10-26",
  };
  assert.deepEqual(
    filterPlans([second, first], base).map((p) => p.id),
    ["first", "second"],
  );
  assert.deepEqual(
    filterPlans([first, second], { ...base, view: "upcoming" }).map(
      (p) => p.id,
    ),
    ["second"],
  );
});
