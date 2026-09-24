import { canonicalDocument, type CloudDocument } from "../../data/documents";
import { validateDraft, type EditDraft } from "../../editor/model";
import {decodeConversation,type ConversationState} from "../../editor/conversation-state";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type ReelSource = {sha256: string; assetId: string; listingId: string};
export type ReelPayload = {draft: EditDraft; listingId: string; sources: ReelSource[];conversation?:ConversationState};
export type EarlierReel = {id: string; label: string; payload: ReelPayload};
export function propertyReelKey(listingId: string): string {
  if (!UUID.test(listingId)) throw new Error("Choose a saved property for this reel.");
  return `edit:${listingId}`;
}
export function reelPayload(value: unknown, listingId: string, allowUnassigned = false): ReelPayload {
  propertyReelKey(listingId);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("This saved reel could not be read.");
  const input = value as Record<string, unknown>;
  if (input.listingId !== listingId && !(allowUnassigned && !input.listingId)) throw new Error("This reel belongs to another property.");
  const draft = validateDraft(input.draft);
  if (!Array.isArray(input.sources) || input.sources.length > 24) throw new Error("The reel's original-file references could not be read.");
  const sources = input.sources.map((raw): ReelSource => {
    const source = raw as ReelSource;
    if (!source || !/^[a-f0-9]{64}$/.test(source.sha256) || !UUID.test(source.assetId) || source.listingId !== listingId)
      throw new Error("This reel contains files from another property. Its earlier copy is preserved.");
    return {sha256: source.sha256, assetId: source.assetId, listingId};
  });
  return {draft, listingId, sources,...(input.conversation===undefined?{}:{conversation:decodeConversation(input.conversation,draft.id)})};
}
/** Read only. The old workspace document and browser keys are never changed. */
export function earlierReels(storage: Pick<Storage, "getItem">, legacyKey: string, listingId: string, cloud: CloudDocument | null): {copies: EarlierReel[]; unreadable: boolean} {
  const copies: EarlierReel[] = []; let unreadable = false;
  const add = (id: string, label: string, value: unknown) => {
    if (value && typeof value === "object" && "listingId" in value && value.listingId && value.listingId !== listingId) return;
    try {
      const payload = reelPayload(value, listingId, true);
      if (!copies.some(copy => canonicalDocument(copy.payload) === canonicalDocument(payload))) copies.push({id, label, payload});
    } catch { unreadable = true; }
  };
  if (cloud) add("account", "Earlier account reel", cloud.payload);
  for (const [suffix, label] of [[":cloud-backup", "Earlier browser backup"], [":recovery", "Recovered browser edit"], ["", "Earlier browser edit"]]) {
    try {
      const saved = storage.getItem(legacyKey + suffix); if (!saved) continue;
      const value = JSON.parse(saved);
      add(`browser${suffix}`, label, suffix === ":cloud-backup" ? value : {draft: value, listingId: null, sources: []});
    } catch { unreadable = true; }
  }
  return {copies, unreadable};
}
