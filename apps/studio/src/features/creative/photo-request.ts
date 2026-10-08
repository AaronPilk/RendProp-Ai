import type { Edit } from "./model";
import { inputForEdit, type PhotoSource } from "./photo-lineage";
import { editedImage } from "./media";

export type PhotoRequestScope = { actor: string; org: string; listing: string };
export type PhotoRequestBody = {
  listing_id: string; original_asset_id: string; image_b64: string; mime: string;
  edit: Edit; space_type: string; label: string; style?: string; prompt?: string;
};
export type PendingPhotoRequest = {
  version: 1; scope: PhotoRequestScope; requestKey: string;
  body: PhotoRequestBody; source: PhotoSource;
  result?: { image_b64: string; mime: string; disclosure: string; provenance: { id: string | null; recorded: boolean } };
};
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const EDITS = ["declutter", "stage", "sky", "twilight", "lawn", "custom"];
export function photoRequestStorageKey(scope: PhotoRequestScope): string {
  if (![scope.actor, scope.org, scope.listing].every(value => typeof value === "string" && UUID.test(value)))
    throw new Error("The photo recovery account could not be verified.");
  return `${scope.actor}:${scope.org}:${scope.listing}`;
}
function validSource(value: PhotoSource, depth = 0): boolean {
  return !!value && depth < 8 && value.file instanceof File && value.file.size > 0 && value.file.size <= 32 * 1024 * 1024 &&
    value.mime === "image/jpeg" && typeof value.base64 === "string" && value.base64.length > 0 && value.base64.length <= 12_000_000 &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(value.base64) && value.preview === `data:image/jpeg;base64,${value.base64}` &&
    Array.isArray(value.disclosures) && value.disclosures.length <= 100 && value.disclosures.every(item => typeof item === "string" && item.length <= 4000) &&
    Array.isArray(value.edits) && value.edits.length <= 100 && value.edits.every(item => typeof item === "string" && item.length <= 4000) &&
    (!value.stageBase || validSource(value.stageBase, depth + 1));
}
/** Store the exact provider request and photo version, including source files.
 * Digests or expiring media links alone cannot reconstruct a lost response. */
export function readPendingPhotoRequest(value: unknown, scope: PhotoRequestScope): PendingPhotoRequest {
  const request = value as PendingPhotoRequest, body = request?.body, source = request?.source;
  if (!request || request.version !== 1 || !request.scope || photoRequestStorageKey(request.scope) !== photoRequestStorageKey(scope) ||
    typeof request.requestKey !== "string" || !UUID.test(request.requestKey) || !body ||
    body.listing_id !== scope.listing || !UUID.test(body.original_asset_id) || !EDITS.includes(body.edit) ||
    typeof body.space_type !== "string" || !body.space_type || body.space_type.length > 80 ||
    typeof body.label !== "string" || body.label.length > 80 ||
    Object.keys(body).some(key => !["listing_id", "original_asset_id", "image_b64", "mime", "edit", "space_type", "label", "style", "prompt"].includes(key)) ||
    (body.edit === "stage" ? !["modern", "rustic", "minimalist", "scandinavian"].includes(body.style ?? "") : body.style !== undefined) ||
    (body.edit === "custom" ? typeof body.prompt !== "string" || !body.prompt.trim() || body.prompt.length > 600 : body.prompt !== undefined) ||
    !validSource(source) || source.originalVerified !== true || !source.original ||
    !(source.original.file instanceof File) || !source.original.file.size || source.original.file.size > 32 * 1024 * 1024 ||
    source.originalAssetId !== body.original_asset_id) throw new Error("The saved photo request could not be verified. No new edit was sent.");
  const input = inputForEdit(source, body.edit);
  if (body.image_b64 !== input.base64 || body.mime !== input.mime)
    throw new Error("The saved photo version changed. No new edit was sent.");
  if (request.result) {
    editedImage(request.result.image_b64, request.result.mime);
    if (typeof request.result.disclosure !== "string" || !request.result.disclosure || request.result.disclosure.length > 1000 ||
      !request.result.provenance || typeof request.result.provenance.recorded !== "boolean" ||
      (request.result.provenance.id !== null && (typeof request.result.provenance.id !== "string" || !UUID.test(request.result.provenance.id))))
      throw new Error("The saved photo result could not be verified. Its request was kept.");
  }
  return request;
}
export class PendingPhotoRequestError extends Error {
  constructor(readonly pending: PendingPhotoRequest) {
    super("An earlier photo request needs confirmation. Recover its preview before starting another edit.");
  }
}

/** One durable slot per account/workspace/property. IndexedDB keeps large
 * source files out of localStorage, and the transaction prevents two tabs
 * from independently starting a new request for the same slot. */
export class PhotoRequestJournal {
  constructor(private readonly factory: IDBFactory = indexedDB) {}
  private async database(): Promise<IDBDatabase> {
    return await new Promise((resolve, reject) => {
      const request = this.factory.open("rendprop-photo-recovery-v1", 1);
      let settled = false;
      const fail = () => { if (!settled) { settled = true; clearTimeout(timer); reject(new Error("Your browser could not keep photo recovery data. Any earlier request may still finish and count.")); } };
      const timer = setTimeout(fail, 5000);
      request.onupgradeneeded = () => { request.result.createObjectStore("requests"); };
      request.onerror = fail;
      request.onblocked = fail;
      request.onsuccess = () => {
        if (settled) { request.result.close(); return; }
        settled = true; clearTimeout(timer); resolve(request.result);
      };
    });
  }
  private async access(scope: PhotoRequestScope, action: "load" | "begin" | "complete" | "forget", pending?: PendingPhotoRequest): Promise<PendingPhotoRequest | null> {
    const key = photoRequestStorageKey(scope), db = await this.database();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction("requests", action === "load" ? "readonly" : "readwrite"), store = transaction.objectStore("requests");
        let result: PendingPhotoRequest | null = null, failure: unknown;
        const timer = setTimeout(() => { failure = new Error("Photo recovery storage timed out. Any earlier request may still finish and count."); transaction.abort(); }, 5000);
        const read = store.get(key);
        read.onsuccess = () => {
          try {
            result = read.result === undefined ? null : readPendingPhotoRequest(read.result, scope);
            if (action === "begin") {
              if (result && !result.result) throw new PendingPhotoRequestError(result);
              result = readPendingPhotoRequest(pending, scope); store.put(result, key);
            } else if (action === "complete" || action === "forget") {
              if (!result || result.requestKey !== pending?.requestKey || JSON.stringify(result.body) !== JSON.stringify(pending.body))
                throw new Error("Another photo request is pending. Its recovery data was kept.");
              if (action === "forget") { store.delete(key); result = null; }
              else { result = readPendingPhotoRequest({ ...result, result: pending.result }, scope); store.put(result, key); }
            }
          } catch (error) { failure = error instanceof DOMException ? new Error("Your browser could not keep photo recovery data. Any earlier request may still finish and count.") : error; transaction.abort(); }
        };
        transaction.oncomplete = () => { clearTimeout(timer); resolve(result); };
        transaction.onabort = transaction.onerror = () => { clearTimeout(timer); reject(failure ?? new Error("Your browser could not keep photo recovery data. Any earlier request may still finish and count.")); };
      });
    } finally { db.close(); }
  }
  load(scope: PhotoRequestScope) { return this.access(scope, "load"); }
  begin(pending: PendingPhotoRequest) { return this.access(pending.scope, "begin", pending); }
  complete(pending: PendingPhotoRequest) { return this.access(pending.scope, "complete", pending); }
  forget(pending: PendingPhotoRequest) { return this.access(pending.scope, "forget", pending); }
}
