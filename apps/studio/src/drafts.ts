import { parseDraft, type EditDraft } from "./editor/model";
import { readPlans, type PlanItem, type StorageLike } from "./workspace";

export type RestoredDrafts = {
  draft?: EditDraft;
  plans: PlanItem[];
  editReadFailed: boolean;
  plannerReadFailed: boolean;
};

/** Each document has independent recovery. A malformed calendar must never make
 * a valid video edit disappear, and a failed read is not permission to overwrite. */
export function restoreDrafts(
  storage: () => StorageLike,
  key: string,
): RestoredDrafts {
  const result: RestoredDrafts = {
    plans: [],
    editReadFailed: false,
    plannerReadFailed: false,
  };
  try {
    const saved = storage().getItem(`${key}:edit`);
    if (saved !== null) result.draft = parseDraft(saved);
  } catch {
    result.editReadFailed = true;
  }
  try {
    result.plans = readPlans(storage(), key);
  } catch {
    result.plannerReadFailed = true;
  }
  return result;
}
