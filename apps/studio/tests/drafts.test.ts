import { test } from "node:test";
import assert from "node:assert/strict";
import { restoreDrafts } from "../src/drafts";
import { EDIT_LIMITS, serializeDraft, type EditDraft } from "../src/editor/model";
import { type PlanItem, type StorageLike } from "../src/workspace";

const key = "rendprop-studio:v1:review-user:review-org";
const edit: EditDraft = {
  schema: 1,
  id: "preserve-existing-edit",
  revision: 7,
  ratio: "16:9",
  title: "Existing room edit",
  audio: "muted",
  clips: [{
    id: "room-photo",
    source: { name: "Room.jpg", size: 12345, lastModified: 100, sha256: "a".repeat(64), kind: "image", width: 1200, height: 800, duration: 0 },
    start: 0,
    end: 3,
    caption: "A space worth sharing",
    focusX: 0.5,
    focusY: 0.5,
  }],
};
const plan: PlanItem = {
  id: "preserve-existing-plan",
  title: "Open house",
  caption: "Meet the space.",
  channel: "Instagram",
  date: "2026-09-15T12:30",
  createdAt: "2026-09-12T12:00:00Z",
  timeZone: "America/New_York",
  scheduledAt: "2026-09-15T16:30:00.000Z",
};
function fixture(editValue: string | null = serializeDraft(edit), plannerValue: string | null = JSON.stringify([plan])) {
  const original = new Map<string, string>();
  if (editValue !== null) original.set(`${key}:edit`, editValue);
  if (plannerValue !== null) original.set(`${key}:planner`, plannerValue);
  const reads: string[] = [];
  let writes = 0;
  const storage: StorageLike = {
    getItem(name) { reads.push(name); return original.get(name) ?? null; },
    setItem() { writes++; throw new Error("restore must not write"); },
  };
  return { original, reads, storage, writes: () => writes };
}

test("restore reads each valid document independently without writing", () => {
  const f = fixture();
  assert.deepEqual(restoreDrafts(() => f.storage, key), { draft: edit, plans: [plan], editReadFailed: false, plannerReadFailed: false });
  assert.deepEqual(f.reads, [`${key}:edit`, `${key}:planner`]);
  assert.equal(f.writes(), 0);
  assert.equal(f.original.get(`${key}:edit`), serializeDraft(edit));
});
for (const malformed of ["{", "null", "{}", '[{"title":"incomplete"}]']) {
  test(`malformed planner ${malformed} cannot suppress a valid video edit`, () => {
    const f = fixture(serializeDraft(edit), malformed);
    const result = restoreDrafts(() => f.storage, key);
    assert.deepEqual(result.draft, edit);
    assert.deepEqual(result.plans, []);
    assert.equal(result.editReadFailed, false);
    assert.equal(result.plannerReadFailed, true);
    assert.equal(f.writes(), 0);
    assert.equal(f.original.get(`${key}:planner`), malformed);
    assert.equal(f.original.get(`${key}:edit`), serializeDraft(edit));
  });
}
for (const malformed of ["{", "null", "{}", "[]", JSON.stringify({ ...edit, schema: 99 })]) {
  test(`malformed edit ${malformed.slice(0, 25)} cannot suppress a valid planner`, () => {
    const f = fixture(malformed);
    const result = restoreDrafts(() => f.storage, key);
    assert.equal(result.draft, undefined);
    assert.deepEqual(result.plans, [plan]);
    assert.equal(result.editReadFailed, true);
    assert.equal(result.plannerReadFailed, false);
    assert.equal(f.writes(), 0);
    assert.equal(f.original.get(`${key}:edit`), malformed);
  });
}
test("missing documents are new drafts, not failed reads", () => {
  const f = fixture(null, null);
  assert.deepEqual(restoreDrafts(() => f.storage, key), { plans: [], editReadFailed: false, plannerReadFailed: false });
  assert.equal(f.original.size, 0);
  assert.equal(f.writes(), 0);
});
test("an existing empty edit string is invalid, never permission to replace it", () => {
  const f = fixture("");
  const result = restoreDrafts(() => f.storage, key);
  assert.equal(result.editReadFailed, true);
  assert.equal(result.draft, undefined);
  assert.deepEqual(result.plans, [plan]);
  assert.equal(f.original.get(`${key}:edit`), "");
  assert.equal(f.writes(), 0);
});
test("an existing empty planner string is invalid, not a missing document", () => {
  const f = fixture(serializeDraft(edit), "");
  const result = restoreDrafts(() => f.storage, key);
  assert.equal(result.plannerReadFailed, true);
  assert.equal(result.editReadFailed, false);
  assert.deepEqual(result.draft, edit);
  assert.equal(f.original.get(`${key}:planner`), "");
  assert.equal(f.writes(), 0);
});
for (const failed of ["edit", "planner"] as const) {
  test(`a throwing ${failed} getItem still attempts and restores the other document`, () => {
    const f = fixture();
    const getItem = f.storage.getItem.bind(f.storage);
    f.storage.getItem = name => { if (name === `${key}:${failed}`) throw new Error("denied read"); return getItem(name); };
    const result = restoreDrafts(() => f.storage, key);
    assert.equal(result.editReadFailed, failed === "edit");
    assert.equal(result.plannerReadFailed, failed === "planner");
    if (failed === "planner") assert.deepEqual(result.draft, edit);
    else assert.deepEqual(result.plans, [plan]);
    assert.equal(f.writes(), 0);
  });
}
test("a throwing storage accessor is retried independently for the second document", () => {
  const f = fixture();
  let accesses = 0;
  const result = restoreDrafts(() => { accesses++; if (accesses === 1) throw new Error("storage unavailable"); return f.storage; }, key);
  assert.equal(accesses, 2);
  assert.equal(result.editReadFailed, true);
  assert.equal(result.plannerReadFailed, false);
  assert.deepEqual(result.plans, [plan]);
  assert.equal(f.writes(), 0);
});
test("persistent storage denial flags both documents without inventing saved success", () => {
  let accesses = 0;
  const result = restoreDrafts(() => { accesses++; throw new Error("storage denied"); }, key);
  assert.equal(accesses, 2);
  assert.deepEqual(result, { plans: [], editReadFailed: true, plannerReadFailed: true });
});
test("oversized saved documents are rejected independently and retained byte-for-byte", () => {
  for (const target of ["edit", "planner"] as const) {
    const oversized = " ".repeat(target === "edit" ? EDIT_LIMITS.draftBytes + 1 : 500_001);
    const f = target === "edit" ? fixture(oversized) : fixture(serializeDraft(edit), oversized);
    const result = restoreDrafts(() => f.storage, key);
    assert.equal(result.editReadFailed, target === "edit");
    assert.equal(result.plannerReadFailed, target === "planner");
    assert.equal(f.original.get(`${key}:${target}`), oversized);
    assert.equal(f.writes(), 0);
  }
});
test("restore cannot read another account or local workspace through key fallback", () => {
  const f = fixture();
  const result = restoreDrafts(() => f.storage, "rendprop-studio:v1:another-user:another-org");
  assert.deepEqual(result, { plans: [], editReadFailed: false, plannerReadFailed: false });
  assert.equal(f.reads.length, 2);
  assert(f.reads.every(name => name.startsWith("rendprop-studio:v1:another-user:another-org:")));
  assert.equal(f.writes(), 0);
});
