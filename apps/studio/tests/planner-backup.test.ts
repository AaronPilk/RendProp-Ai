import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MAX_PLAN_BACKUP_BYTES,
  bindPlanDate,
  confirmPlanImport,
  downloadBlob,
  parsePlanBackup,
  planBackupFile,
  planImportSnapshot,
  previewPlanImport,
  readPlanBackupFile,
  readPlans,
  validatePlans,
  writePlans,
} from "../src/workspace";
import type { PlanItem } from "../src/workspace";

const exportedAt = "2026-09-12T18:15:30.123Z";
const item: PlanItem = {
  id: "test-post", title: "Open house 🏠", caption: "A caption\r\nwith lines and café.",
  channel: "Instagram", createdAt: "2026-09-12T12:00:00Z",
  ...bindPlanDate("2026-11-01T01:30", "America/New_York", "2026-11-01T06:30:00.000Z"),
};
const incoming = { ...item, id: "another-post", channel: "YouTube" as const };
const envelope = (plans: unknown = [incoming]) => ({
  format: "rendprop-content-plans", version: 1, exportedAt, plans,
});
const text = (value: unknown = envelope()) => JSON.stringify(value);
const file = (value: string) => new Blob([value], { type: "application/json" });

test("versioned whole-queue export round-trips Unicode, IDs, captions and the selected DST occurrence", async () => {
  const plans = [item, incoming];
  const backup = planBackupFile(plans, exportedAt);
  assert.equal(backup.filename, "rendprop-content-plans-2026-09-12T18-15-30-123Z-2-plans.json");
  const parsed = await readPlanBackupFile(file(backup.text));
  assert.deepEqual(parsed, envelope(plans));
  assert.deepEqual(plans, [item, incoming]);
  assert.equal(parsed.plans[0].scheduledAt, "2026-11-01T06:30:00.000Z");
  assert.equal(parsed.plans[0].timeZone, "America/New_York");
});
test("legacy timezone-unbound records retain their explicit missing-zone state", () => {
  const { timeZone, scheduledAt, ...legacy } = item;
  assert.deepEqual(parsePlanBackup(planBackupFile([legacy], exportedAt).text).plans, [legacy]);
  assert(!Object.hasOwn(parsePlanBackup(text(envelope([legacy]))).plans[0], "timeZone"));
});
test("an empty backup is valid and has an explicit zero-plan replacement result", () => {
  assert.equal(parsePlanBackup(planBackupFile([], exportedAt).text).plans.length, 0);
  assert.deepEqual(previewPlanImport([item], [], "replace").plans, []);
  assert.deepEqual(previewPlanImport([item], [], "merge").plans, [item]);
});
test("maximum-size valid fields export all 100 records without truncating escaped characters", () => {
  const plans = Array.from({ length: 100 }, (_, i) => ({
    ...item, id: `plan-${i}`, title: "t" + "\u0001".repeat(119), caption: "\u0001".repeat(2200),
  }));
  const backup = planBackupFile(plans, exportedAt);
  assert(new TextEncoder().encode(backup.text).length < MAX_PLAN_BACKUP_BYTES);
  assert.deepEqual(parsePlanBackup(backup.text).plans, plans);
});
test("export refuses duplicate identities, over-cap queues and invalid timestamps", () => {
  assert.throws(() => planBackupFile([item, item], exportedAt), /duplicate/);
  assert.throws(() => planBackupFile(Array(101).fill(item), exportedAt), /100/);
  assert.throws(() => planBackupFile([item], "2026-02-30T12:00:00Z"), /real calendar/);
});
for (const [name, invalid] of [
  ["malformed JSON", "{"],
  ["bare legacy array", text([item])],
  ["null", "null"],
  ["wrong document format", text({ ...envelope(), format: "rendprop-video-edit" })],
  ["future schema version", text({ ...envelope(), version: 2 })],
  ["string schema version", text({ ...envelope(), version: "1" })],
  ["unknown envelope field", text({ ...envelope(), futureCalendar: true })],
  ["unknown plan field", text(envelope([{ ...item, socialJobId: "not-preserved" }]))],
  ["missing exported date", text({ ...envelope(), exportedAt: undefined })],
  ["impossible exported date", text({ ...envelope(), exportedAt: "2026-02-30T12:00:00Z" })],
  ["missing plans", text({ format: "rendprop-content-plans", version: 1, exportedAt })],
  ["duplicate plan IDs", text(envelope([item, item]))],
  ["101 plans", text(envelope(Array.from({ length: 101 }, (_, i) => ({ ...item, id: `p-${i}` }))))],
  ["one invalid plan amid valid ones", text(envelope([item, { ...incoming, date: "2026-02-30T12:30" }]))],
  ["inconsistent timezone instant", text(envelope([{ ...item, timeZone: "UTC" }]))],
  ["incomplete timezone pair", text(envelope([{ ...item, scheduledAt: undefined }]))],
  ["ID property injection", text(envelope([{ ...item, id: "a\rUID:another" }]))],
] as const) {
  test(`invalid fixture refuses ${name} without accepting a partial queue`, () => {
    const current = Object.freeze([Object.freeze({ ...item })]);
    const before = JSON.stringify(current);
    assert.throws(() => parsePlanBackup(invalid));
    assert.equal(JSON.stringify(current), before);
  });
}
test("file-size limit is checked before reading and is measured in bytes", async () => {
  let reads = 0;
  for (const size of [0, -1, NaN, Infinity, 1.5, MAX_PLAN_BACKUP_BYTES + 1]) {
    await assert.rejects(readPlanBackupFile({ size, arrayBuffer: async () => { reads++; return new ArrayBuffer(0); } }), /2 MiB/);
  }
  assert.equal(reads, 0);
  const multibyte = "\"" + "界".repeat(Math.ceil(MAX_PLAN_BACKUP_BYTES / 3)) + "\"";
  assert(multibyte.length < MAX_PLAN_BACKUP_BYTES);
  assert.throws(() => parsePlanBackup(multibyte), /2 MiB/);
});
test("exact limit is permitted but a byte beyond it is refused", async () => {
  const valid = text();
  const exact = valid + " ".repeat(MAX_PLAN_BACKUP_BYTES - new TextEncoder().encode(valid).length);
  assert.equal((await readPlanBackupFile(file(exact))).plans.length, 1);
  await assert.rejects(readPlanBackupFile(file(exact + " ")), /2 MiB/);
});
test("invalid UTF-8, read failure and changed file length fail closed", async () => {
  await assert.rejects(readPlanBackupFile(new Blob([new Uint8Array([0xff])])), /UTF-8/);
  await assert.rejects(readPlanBackupFile({ size: 1, arrayBuffer: async () => { throw Error("file unreadable"); } }), /unreadable/);
  await assert.rejects(readPlanBackupFile({ size: 1, arrayBuffer: async () => new ArrayBuffer(2) }), /changed/);
  await assert.rejects(readPlanBackupFile({ size: 1, arrayBuffer: async () => new ArrayBuffer(MAX_PLAN_BACKUP_BYTES + 1) }), /2 MiB/);
});
test("merge preview retains every current plan and never mutates either input", () => {
  const current = Object.freeze([Object.freeze({ ...item })]) as unknown as PlanItem[];
  const imports = Object.freeze([Object.freeze({ ...incoming })]) as unknown as PlanItem[];
  const preview = previewPlanImport(current, imports, "merge");
  assert.deepEqual(preview, { plans: [item, incoming], importedCount: 1, existingCount: 1 });
  preview.plans[0].caption = "preview-only mutation";
  assert.equal(current[0].caption, item.caption);
});
test("both identical and changed overlapping IDs block merge rather than overwrite or silently dedupe", () => {
  for (const duplicate of [item, { ...item, caption: "Changed in another browser" }])
    assert.throws(() => previewPlanImport([item], [duplicate], "merge"), /Merge cannot overwrite or duplicate/);
  assert.deepEqual(previewPlanImport([item], [{ ...item, caption: "Imported replacement" }], "replace").plans,
    [{ ...item, caption: "Imported replacement" }]);
});
test("combined merge cap rejects 101 without slicing; replace can still import a valid smaller queue", () => {
  const current = Array.from({ length: 100 }, (_, i) => ({ ...item, id: `p-${i}` }));
  assert.throws(() => previewPlanImport(current, [incoming], "merge"), /101 plans/);
  assert.equal(previewPlanImport(current.slice(0, 99), [incoming], "merge").plans.length, 100);
  assert.deepEqual(previewPlanImport(current, [incoming], "replace").plans, [incoming]);
  assert.equal(current.length, 100);
});
test("invalid mode and invalid import never reach the saving callback", () => {
  let writes = 0;
  const save = () => { writes++; };
  assert.throws(() => confirmPlanImport([item], [incoming], "append" as "merge", planImportSnapshot([item]), save), /Merge or Replace/);
  assert.throws(() => confirmPlanImport([item], [{ ...incoming, title: "" }], "replace", planImportSnapshot([item]), save));
  assert.equal(writes, 0);
});
test("stale preview rejects changed values, order and removed plans before writing", () => {
  const original = [item, incoming];
  const snapshot = planImportSnapshot(original);
  let writes = 0;
  for (const changed of [[{ ...item, caption: "new edit" }, incoming], [incoming, item], [item]]) {
    assert.throws(() => confirmPlanImport(changed, [], "replace", snapshot, () => { writes++; }), /changed after this preview/);
  }
  assert.equal(writes, 0);
  assert.deepEqual(original, [item, incoming]);
});
test("preview and cancellation perform no writes; confirmation persists exactly once before returning", () => {
  let current = [item], writes = 0;
  const snapshot = planImportSnapshot(current);
  const preview = previewPlanImport(current, [incoming], "merge");
  assert.equal(writes, 0);
  assert.deepEqual(current, [item]); // Closing this preview invokes no save callback.
  confirmPlanImport(current, [incoming], "merge", snapshot, (next) => { writes++; current = next; });
  assert.equal(writes, 1);
  assert.deepEqual(current, preview.plans);
});
test("quota failure retains exact saved bytes/current state/preview and permits an explicit retry", () => {
  const original = JSON.stringify([item]);
  let bytes = original, current = [item], writes = 0, fail = true;
  const storage = {
    getItem: () => bytes,
    setItem: (_key: string, value: string) => { writes++; if (fail) throw Error("QuotaExceededError"); bytes = value; },
  };
  const preview = previewPlanImport(current, [incoming], "replace"), snapshot = planImportSnapshot(current);
  const onSave = (next: PlanItem[]) => { writePlans(storage, "local", next); current = next; };
  assert.throws(() => confirmPlanImport(current, [incoming], "replace", snapshot, onSave), /QuotaExceededError/);
  assert.equal(bytes, original);
  assert.deepEqual(current, [item]);
  assert.deepEqual(preview.plans, [incoming]);
  fail = false;
  confirmPlanImport(current, [incoming], "replace", snapshot, onSave);
  assert.equal(writes, 2);
  assert.deepEqual(readPlans(storage, "local"), [incoming]);
});
test("oversized escaped draft cannot replace a queue with bytes the existing reader would reject", () => {
  const plans = Array.from({ length: 100 }, (_, i) => ({ ...item, id: `p-${i}`, caption: "\u0001".repeat(2200) }));
  assert.equal(validatePlans(plans).length, 100);
  assert(JSON.stringify(plans).length > 500_000);
  let writes = 0;
  assert.throws(() => confirmPlanImport([item], plans, "replace", planImportSnapshot([item]), (next) => {
    writePlans({ getItem: () => JSON.stringify([item]), setItem: () => { writes++; } }, "local", next);
  }), /storage limits/);
  assert.equal(writes, 0);
});
for (const clickThrows of [false, true]) {
  test(`download URL and attached anchor cleaned up when click ${clickThrows ? "fails" : "succeeds"}`, (context) => {
    const previous = Object.getOwnPropertyDescriptor(globalThis, "document");
    const events: string[] = [];
    let callback: (() => void) | undefined;
    const anchor = { href: "", download: "", click: () => {
      events.push("click"); if (clickThrows) throw Error("download refused");
    }, remove: () => events.push("remove") };
    context.mock.method(URL, "createObjectURL", () => { events.push("create-url"); return "blob:test-backup"; });
    context.mock.method(URL, "revokeObjectURL", (url: string) => { assert.equal(url, "blob:test-backup"); events.push("revoke-url"); });
    context.mock.method(globalThis, "setTimeout", ((fn: () => void, delay: number) => {
      assert.equal(delay, 30_000); callback = fn; return 1;
    }) as unknown as typeof setTimeout);
    Object.defineProperty(globalThis, "document", { configurable: true, value: {
      createElement: (tag: string) => { assert.equal(tag, "a"); return anchor; },
      body: { append: (element: unknown) => { assert.equal(element, anchor); events.push("append"); } },
    } });
    try {
      const action = () => downloadBlob(file(text()), "backup.json");
      if (clickThrows) assert.throws(action, /download refused/); else action();
      assert.equal(anchor.href, "blob:test-backup");
      assert.equal(anchor.download, "backup.json");
      assert(callback, "the actual download helper must schedule URL release");
      callback();
      assert.deepEqual(events, ["create-url", "append", "click", "remove", "revoke-url"]);
    } finally {
      if (previous) Object.defineProperty(globalThis, "document", previous);
      else Reflect.deleteProperty(globalThis, "document");
    }
  });
}
