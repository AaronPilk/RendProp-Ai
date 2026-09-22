import { canonicalDocument } from "../../data/documents";
import { validatePlans, type PlanItem } from "../../workspace";

export type PlannerStorage = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;
export type PlannerRecovery = { keys: string[]; items: PlanItem[]; pending: boolean };
export const samePlans = (left: PlanItem[], right: PlanItem[]) => canonicalDocument(left) === canonicalDocument(right);

function recoveryKeys(storage: PlannerStorage, key: string): string[] {
  const keys: string[] = [];
  for (let index = 0; index < storage.length; index++) {
    const candidate = storage.key(index);
    if (candidate === `${key}:recovery` || candidate?.startsWith(`${key}:recovery:`) || candidate?.startsWith(`${key}:pending:`)) keys.push(candidate);
  }
  return keys;
}

function readCopies(storage: PlannerStorage, key: string): { copies: PlannerRecovery[]; unreadable: boolean } {
  const copies: PlannerRecovery[] = [];
  let unreadable = false;
  for (const source of recoveryKeys(storage, key)) {
    try {
      const raw = storage.getItem(source);
      if (raw === null) continue;
      const items = validatePlans(JSON.parse(raw));
      const matching = copies.find(copy => samePlans(copy.items, items));
      if (matching) { matching.keys.push(source); matching.pending ||= source.startsWith(`${key}:pending:`); }
      else copies.push({ keys: [source], items, pending: source.startsWith(`${key}:pending:`) });
    } catch { unreadable = true; /* Never delete a copy that this version cannot read. */ }
  }
  return { copies, unreadable };
}

/** Each editor journals separately so a second tab cannot overwrite an interrupted save. */
export function writePendingPlans(storage: PlannerStorage, key: string, editorId: string, items: PlanItem[]): void {
  storage.setItem(`${key}:pending:${editorId}`, JSON.stringify(validatePlans(items)));
}

export function keepPlannerRecovery(storage: PlannerStorage, key: string, items: PlanItem[]): PlannerRecovery {
  const plans = validatePlans(items);
  const existing = readCopies(storage, key).copies.find(copy => samePlans(copy.items, plans));
  if (existing) return existing;
  const source = `${key}:recovery:${crypto.randomUUID()}`;
  storage.setItem(source, JSON.stringify(plans));
  return { keys: [source], items: plans, pending: false };
}

/** Remove only the reviewed value; a concurrent tab may have updated a key. */
export function removePlannerRecovery(storage: PlannerStorage, copy: PlannerRecovery): void {
  for (const key of copy.keys) {
    const raw = storage.getItem(key);
    if (raw !== null && samePlans(validatePlans(JSON.parse(raw)), copy.items)) storage.removeItem(key);
  }
}

export function acknowledgePlannerPlans(storage: PlannerStorage, key: string, confirmed: PlanItem[]): void {
  for (const copy of readCopies(storage, key).copies) if (samePlans(copy.items, confirmed)) removePlannerRecovery(storage, copy);
}

export function openPlannerRecovery(storage: PlannerStorage, key: string, cloud: PlanItem[] | null): {
  items: PlanItem[]; migrate: boolean; copies: PlannerRecovery[]; unreadable: boolean;
} {
  let unreadable = false;
  const legacy = storage.getItem(key);
  if (legacy !== null) {
    try {
      const items = validatePlans(JSON.parse(legacy)), canonical = canonicalDocument(items);
      if (storage.getItem(`${key}:legacy-accounted`) !== canonical) {
        // Preserve browser data before marking it considered. Leave its original
        // storage untouched so an unreadable backup is never overwritten.
        if (cloud === null || !samePlans(items, cloud)) keepPlannerRecovery(storage, key, items);
        storage.setItem(`${key}:legacy-accounted`, canonical);
      }
    } catch { unreadable = true; }
  }
  if (cloud !== null) acknowledgePlannerPlans(storage, key, cloud);
  const result = readCopies(storage, key);
  const migrate = cloud === null && result.copies.length === 1;
  return { items: cloud ?? (migrate ? result.copies[0].items : []), migrate, copies: result.copies, unreadable: unreadable || result.unreadable };
}
