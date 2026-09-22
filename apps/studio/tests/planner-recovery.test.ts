import assert from "node:assert/strict";
import { test } from "node:test";
import { acknowledgePlannerPlans, keepPlannerRecovery, openPlannerRecovery, removePlannerRecovery, writePendingPlans, type PlannerStorage } from "../src/features/sync/planner-recovery";
import type { PlanItem } from "../src/workspace";
const key = "workspace:agent:office:plans";
function storage(): PlannerStorage {
  const data = new Map<string, string>();
  return { get length() { return data.size; }, key: index => [...data.keys()][index] ?? null, getItem: key => data.get(key) ?? null, setItem: (key, value) => { data.set(key, value); }, removeItem: key => { data.delete(key); } };
}
const plan = (title: string, id = "plan-one"): PlanItem => ({ id, title, caption: "Tour the property", channel: "Instagram", date: "2026-09-15T10:00", createdAt: "2026-09-14T12:00:00Z" });

test("validated legacy plans with no cloud document are selected for migration and kept until receipt", () => {
  const s = storage(), plans = [plan("Legacy plan")]; s.setItem(key, JSON.stringify(plans));
  const opened = openPlannerRecovery(s, key, null);
  assert.equal(opened.migrate, true); assert.deepEqual(opened.items, plans); assert.equal(opened.copies.length, 1);
  const confirmed = openPlannerRecovery(s, key, plans);
  assert.equal(confirmed.copies.length, 0); assert.equal(confirmed.migrate, false);
  assert.deepEqual(openPlannerRecovery(s, key, [plan("Later office edit")]).copies, []);
});

test("an interrupted edit survives returning to an older cloud version without overwriting it", () => {
  const s = storage(), remote = [plan("Saved account plan")], pending = [plan("Work after returning to the office")];
  writePendingPlans(s, key, "tab-a", pending);
  const opened = openPlannerRecovery(s, key, remote);
  assert.deepEqual(opened.items, remote); assert.equal(opened.migrate, false); assert.deepEqual(opened.copies[0].items, pending); assert.equal(opened.copies[0].pending, true);
  assert.deepEqual(openPlannerRecovery(s, key, remote).copies, opened.copies);
});

test("a lost response is acknowledged by identical content despite object key order, without a second write", () => {
  const s = storage(), plans = [plan("Saved once")]; writePendingPlans(s, key, "tab", plans);
  const reordered = plans.map(p => Object.fromEntries(Object.entries(p).reverse())) as PlanItem[];
  assert.equal(openPlannerRecovery(s, key, reordered).copies.length, 0);
  assert.equal(s.getItem(`${key}:pending:tab`), null);
});

test("two tab journals and an existing recovery are all preserved, including equal creation timestamps", () => {
  const s = storage(); writePendingPlans(s, key, "first", [plan("First tab")]); writePendingPlans(s, key, "second", [plan("Second tab")]);
  s.setItem(`${key}:recovery`, JSON.stringify([plan("Older recoverable copy")]));
  const opened = openPlannerRecovery(s, key, [plan("Cloud")]);
  assert.equal(opened.copies.length, 3); assert.equal(opened.migrate, false);
  assert.equal(openPlannerRecovery(s, key, null).migrate, false, "Do not guess among several different copies");
});

test("discard affects only the reviewed content and cannot delete a newer value from that tab", () => {
  const s = storage(); writePendingPlans(s, key, "tab", [plan("Reviewed")]);
  const copy = openPlannerRecovery(s, key, [plan("Cloud")]).copies[0];
  writePendingPlans(s, key, "tab", [plan("Newer browser edit")]); removePlannerRecovery(s, copy);
  assert.equal(openPlannerRecovery(s, key, [plan("Cloud")]).copies[0].items[0].title, "Newer browser edit");
});

test("applying a reviewed copy can preserve both previous account plans and pending replacement until receipt", () => {
  const s = storage(), account = [plan("Account")], pending = [plan("Recovered")];
  const previous = keepPlannerRecovery(s, key, account); writePendingPlans(s, key, "tab", pending);
  assert.equal(openPlannerRecovery(s, key, null).copies.length, 2);
  acknowledgePlannerPlans(s, key, pending);
  assert.deepEqual(openPlannerRecovery(s, key, pending).copies, [previous]);
});

test("unreadable legacy data and invalid pending records are preserved rather than migrated or overwritten", () => {
  const s = storage(); s.setItem(key, "{broken"); s.setItem(`${key}:pending:old`, JSON.stringify([{ unknown: true }]));
  const opened = openPlannerRecovery(s, key, null);
  assert.equal(opened.unreadable, true); assert.equal(opened.migrate, false); assert.equal(s.getItem(key), "{broken");
  writePendingPlans(s, key, "new", [plan("Valid new work")]); acknowledgePlannerPlans(s, key, [plan("Valid new work")]);
  assert.equal(s.getItem(key), "{broken"); assert.ok(s.getItem(`${key}:pending:old`));
});

test("account and organization recovery scopes remain isolated", () => {
  const s = storage(); writePendingPlans(s, key, "tab", [plan("Private office plan")]);
  assert.equal(openPlannerRecovery(s, "workspace:other:office:plans", null).copies.length, 0);
  assert.equal(openPlannerRecovery(s, "workspace:agent:other:plans", null).copies.length, 0);
  assert.equal(openPlannerRecovery(s, key, []).copies.length, 1);
});

test("empty pending queue is a deliberate deletion, preserved for review rather than inferred from timestamps", () => {
  const s = storage(); writePendingPlans(s, key, "tab", []);
  assert.deepEqual(openPlannerRecovery(s, key, [plan("Still in account")]).copies[0].items, []);
  assert.equal(openPlannerRecovery(s, key, []).copies.length, 0);
});
