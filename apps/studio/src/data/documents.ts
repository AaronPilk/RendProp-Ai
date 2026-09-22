import { StudioError } from "./config";
import type { StudioServices } from "./services";
export type CloudDocument = { key: string; kind: string; listing_id: string | null; revision: number; payload: Record<string, unknown>; updated_at: string };
export function decodeDocument(raw: unknown, key: string): CloudDocument | null {
  if (!raw || typeof raw !== "object" || !("document" in raw)) throw new Error("Saved work could not be read.");
  const value = (raw as {document: unknown}).document;
  if (value === null) return null;
  const doc = value as CloudDocument;
  if (doc.key !== key || !Number.isSafeInteger(doc.revision) || doc.revision < 1 ||
    !doc.payload || typeof doc.payload !== "object" || Array.isArray(doc.payload) || !Number.isFinite(Date.parse(doc.updated_at)))
    throw new Error("Saved work could not be read.");
  return doc;
}
export type SyncState = "loading" | "saved" | "saving" | "offline" | "conflict";
/** JSONB may reorder every object key. Compare document values, never response key order. */
export function canonicalDocument(value: unknown): string {
  const ordered = (item: unknown): unknown => {
    if (Array.isArray(item)) return item.map(ordered);
    if (item && typeof item === "object") return Object.fromEntries(Object.entries(item).filter(([, v]) => v !== undefined).sort(([a], [b]) => a.localeCompare(b)).map(([key, v]) => [key, ordered(v)]));
    return item;
  };
  return JSON.stringify(ordered(value));
}
/** One sequential CAS writer per document. A lost response is reconciled by read,
 * never a duplicate write. Conflicts preserve the local draft for explicit review. */
export class DocumentSync {
  private revision = 0;
  private saved = "";
  private pending: Record<string, unknown> | null = null;
  private timer?: ReturnType<typeof setTimeout>;
  private running = false;
  private stopped = false;
  private uncertain: { payload: string; revision: number } | null = null;
  private controller = new AbortController();
  state: SyncState = "loading";
  constructor(private services: StudioServices, readonly orgId: string, readonly key: string,
    private changed: (state: SyncState) => void) {}
  private status(state: SyncState) { this.state = state; if (!this.stopped) this.changed(state); }
  async read(): Promise<CloudDocument | null> {
    const raw = await this.services.api(`/functions/v1/studio/documents?key=${encodeURIComponent(this.key)}`, {orgId:this.orgId,signal:this.controller.signal});
    return decodeDocument(raw,this.key);
  }
  async open(): Promise<CloudDocument | null> {
    try {
      const doc = await this.read();
      if (this.stopped) return null;
      this.revision = doc?.revision ?? 0;
      this.saved = doc ? canonicalDocument(doc.payload) : "";
      this.status("saved");
      return doc;
    } catch(error) { this.status("offline"); throw error; }
  }
  queue(payload: Record<string, unknown>) {
    if (this.stopped) return;
    if (canonicalDocument(payload) === this.saved && !this.running && !this.uncertain && (this.state === "saved" || this.state === "saving")) { this.pending=null; if(this.state==="saving")this.status("saved"); return; }
    // A caller adding a source receipt must not mutate an already dispatched save.
    this.pending = structuredClone(payload);
    if (this.state === "conflict" || this.state === "offline" || this.state === "loading") return;
    this.status("saving");
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { void this.flush(); }, 650);
  }
  async flush(): Promise<void> {
    if (this.stopped || this.running || !this.pending || this.state === "conflict" || this.state === "offline" || this.state === "loading") return;
    this.running = true;
    const payload = this.pending;
    const attempt = { payload: canonicalDocument(payload), revision: this.revision };
    this.pending = null;
    try {
      const kind = this.key.split(":")[0];
      const doc = decodeDocument(await this.services.api("/functions/v1/studio/documents", {
        orgId:this.orgId,method:"POST",signal:this.controller.signal,
        body:{key:this.key,kind,...(this.key.includes(":") ? {listing_id:this.key.split(":")[1]} : {}),expected_revision:this.revision,payload},
      }),this.key);
      if (!doc) throw new Error("Save confirmation was missing.");
      if (doc.revision !== attempt.revision + 1 || canonicalDocument(doc.payload) !== attempt.payload) throw new Error("Save confirmation did not match this draft.");
      this.uncertain = null;
      this.revision = doc.revision; this.saved=canonicalDocument(doc.payload);
      if (this.pending && canonicalDocument(this.pending) === this.saved) this.pending = null;
      this.status(this.pending ? "saving" : "saved");
    } catch(error) {
      this.pending ??= payload;
      this.uncertain = error instanceof StudioError && error.status === 409 ? null : attempt;
      this.status(error instanceof StudioError && error.status===409 ? "conflict" : "offline");
    } finally {
      this.running=false;
      if (this.pending && this.state === "saving") void this.flush();
    }
  }
  async retry(): Promise<void> {
    if (this.stopped || this.running) return;
    try {
      const doc=await this.read();
      if (this.stopped || this.running) return;
      const remote=doc ? canonicalDocument(doc.payload) : "";
      const ownUncertainSave = this.uncertain && doc?.revision === this.uncertain.revision + 1 && remote === this.uncertain.payload;
      if ((doc?.revision ?? 0)!==this.revision && remote!==canonicalDocument(this.pending) && !ownUncertainSave) {
        this.status("conflict"); return;
      }
      this.revision=doc?.revision ?? 0; this.saved=remote;
      this.uncertain = null;
      if (this.pending && canonicalDocument(this.pending)===remote) this.pending=null;
      this.status(this.pending ? "saving" : "saved");
      await this.flush();
    } catch { this.status("offline"); }
  }
  get hasUnsavedWork(): boolean { return this.running || this.pending !== null || this.uncertain !== null || this.state === "conflict"; }
  /** When another device saves, ask to reload instead of silently replacing an open edit. */
  async checkRemote(): Promise<void> {
    if (this.stopped || this.state !== "saved" || this.hasUnsavedWork) return;
    const revision = this.revision;
    try {
      const doc = await this.read();
      if (this.stopped || this.state !== "saved" || this.hasUnsavedWork || this.revision !== revision) return;
      if ((doc?.revision ?? 0) !== revision) this.status("conflict");
    } catch { /* Keep the last confirmed save; user edits still trigger visible retry state. */ }
  }
  dispose() { this.stopped=true; clearTimeout(this.timer); this.controller.abort(); }
}
