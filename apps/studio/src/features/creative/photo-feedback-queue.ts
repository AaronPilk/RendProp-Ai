/** Optional explicit feedback (Useful / Needs work) and separate outcome signals
 * for one exact AI photo output version: its media_provenance id. Contract:
 * docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md §4. Each item stores its exact
 * request body in this browser before any request (§4.6.1) and is resent
 * unchanged until the server answers definitively, so retries never add a row.
 * A client_key is bound to one provenance id for good. Nothing here starts,
 * retries or pays for a generation, and no save, export or publication waits
 * for it. Storage follows the scoped localStorage journals in features/sync. */
import { StudioError } from "../../data/config";
import type { StudioServices } from "../../data/services";
import { FEEDBACK_REASONS } from "./photo-feedback-reasons";

export type Verdict = "useful" | "needs_work";
export type Content = { verdict: Verdict; reasons: string[]; note?: string };
export type FeedbackScope = { actor: string; library: string };
export type FeedbackStorage = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;
/** Studio sends these three §4.2 signals, each after its action has happened. */
export const SIGNAL_DETAILS = { accuracy_ack: "custom_review", manual_selection: "gallery_save", export: "download" };
export type SignalName = keyof typeof SIGNAL_DETAILS;
export type FeedbackItem = { actor: string; library: string; id: string; path: "" | "/signal"; state: "queued" | "sent" | "dropped"; at: number;
  body: Partial<Content> & { output: { provenance_id: string; output_sha256?: string }; client_key: string; revision?: number; signal?: SignalName; detail?: string; platform: "studio" } };
type Outcome = "sent" | "dropped" | "retry" | "wait";

const scoped = (scope: FeedbackScope) => `rendprop-photo-feedback-v1:${scope.actor}:${scope.library}:`;
const keyOf = (scope: FeedbackScope, item: FeedbackItem) => scoped(scope) + item.id + (item.path && ":" + item.body.signal);
const uuid = (value: string) => /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const count = (value: unknown) => Number.isSafeInteger(value) && (value as number) > 0 ? value as number : 0;
const newKey = () => `studio:${crypto.randomUUID()}`;
/** §3.2 content in canonical reason order, or null when it breaks the rules. */
export function content(value: unknown): Content | null {
  const v = value as Partial<Content> | null, reasons = FEEDBACK_REASONS.filter(reason => v?.reasons?.includes(reason)), note = v?.note || undefined;
  return reasons.length === v?.reasons?.length && (v.verdict === "useful" ? !reasons.length : v.verdict === "needs_work" && reasons.length > 0) &&
    (note === undefined || typeof note === "string" && note.length <= 500) ? { verdict: v.verdict!, reasons, note } : null;
}
export const same = (a: Content, b: Partial<Content>) => a.verdict === b.verdict && a.reasons.join() === b.reasons?.join() && (a.note ?? "") === (b.note ?? "");
function load(storage: FeedbackStorage, scope: FeedbackScope, key: string): FeedbackItem | null {
  try {
    const item: FeedbackItem = JSON.parse(storage.getItem(key)!);
    // An item must sit under the key derived from its own output, so a stored
    // verdict or signal can never be sent for a different image.
    return item.actor === scope.actor && item.library === scope.library && (item.path === "" || item.path === "/signal") && item.body.output.provenance_id === item.id &&
      key === keyOf(scope, item) ? item : null;
  } catch { return null; }
}
const write = (storage: FeedbackStorage, scope: FeedbackScope, item: FeedbackItem) => { storage.setItem(keyOf(scope, item), JSON.stringify(item)); return item; };

/** Commits the verdict before any request. An unchanged verdict keeps its
 * revision; a change keeps this output's key and bumps the revision (§4.7). */
export function recordFeedback(storage: FeedbackStorage, scope: FeedbackScope, input: Content & { provenance_id: string; output_sha256?: string }): FeedbackItem {
  const id = input.provenance_id.toLowerCase(), prior = load(storage, scope, scoped(scope) + id), next = content({ ...input, note: input.note?.trim() }), sha = input.output_sha256;
  const pinned = prior?.body.output.output_sha256;
  if (!uuid(id) || !next || sha && !/^[a-f0-9]{64}$/.test(sha)) throw Error("invalid feedback");
  if (pinned && sha && pinned !== sha) throw Error("feedback for a different image");
  if (prior && prior.state !== "dropped" && same(next, prior.body)) return prior;
  return write(storage, scope, { actor: scope.actor, library: scope.library, id, path: "", state: "queued", at: Date.now(), body: {
    output: { provenance_id: id, output_sha256: sha || pinned }, client_key: prior?.body.client_key ?? newKey(), revision: (prior?.body.revision ?? 0) + 1, ...next, platform: "studio" } });
}
/** One append-only signal per (output, actor, signal). Its key is derived from
 * the output, so a retry, another tab or another device can only replay it. */
export function recordSignal(storage: FeedbackStorage, scope: FeedbackScope, provenance: string, signal: SignalName): FeedbackItem | null {
  const id = provenance.toLowerCase(), item: FeedbackItem = { actor: scope.actor, library: scope.library, id, path: "/signal", state: "queued", at: Date.now(),
    body: { output: { provenance_id: id }, client_key: `studio:${signal}:${id}`, signal, detail: SIGNAL_DETAILS[signal], platform: "studio" } };
  return uuid(id) && !load(storage, scope, keyOf(scope, item)) ? write(storage, scope, item) : null;
}
/** Keys of queued items, oldest first. Finished feedback is forgotten after 30 days. */
export function queuedFeedback(storage: FeedbackStorage, scope: FeedbackScope, now = Date.now()): string[] {
  const found: [number, string][] = [];
  for (let index = storage.length; index--;) {
    const key = storage.key(index)!, item = key.startsWith(scoped(scope)) ? load(storage, scope, key) : null;
    if (item?.state === "queued") found.push([item.at, key]);
    else if (item && !(now - item.at < 2_592_000_000)) storage.removeItem(key);
  }
  return found.sort((a, b) => a[0] - b[0]).map(entry => entry[1]);
}
/** §4.5/§4.6: refusals drop the item; transport, auth, rate and server failures
 * retry with backoff; anything else waits for the next trigger. */
function classify(error: unknown): Exclude<Outcome, "sent"> {
  const { status, code } = error instanceof StudioError ? error : { status: 0, code: "" };
  return status === undefined ? code === "network" || code === "timeout" ? "retry" : "wait"
    : status === 401 || status === 408 || status === 429 || status >= 500 ? "retry"
    : status === 404 ? code === "output_not_found" ? "dropped" : "wait" : status >= 400 ? "dropped" : "wait";
}

export type PhotoFeedbackQueue = ReturnType<typeof createPhotoFeedbackQueue>;
export function createPhotoFeedbackQueue(services: Pick<StudioServices, "api" | "getSnapshot">, scope: FeedbackScope, storage: FeedbackStorage,
  schedule = (ms: number, run: () => void) => { const timer = setTimeout(run, ms); return () => clearTimeout(timer); }) {
  const abort = new AbortController(), listeners = new Set<() => void>(), version = services.getSnapshot().identityVersion;
  let running: Promise<void> | null = null, again = false, failures = 0, cancel = () => {};
  const notify = () => listeners.forEach(listener => listener());
  // Never send one account's queue with another account's session.
  const current = () => {
    const now = services.getSnapshot();
    return !abort.signal.aborted && now.status === "signed-in" && now.identityVersion === version && now.identity?.userId === scope.actor && !now.identity.isAnonymous;
  };
  const save = (item: FeedbackItem) => { write(storage, scope, item); notify(); };
  async function deliver(key: string): Promise<Outcome> {
    let adopting = false;
    for (let attempt = 0; attempt < 4; attempt++) {
      const raw = storage.getItem(key), item = load(storage, scope, key);
      if (item?.state !== "queued") return "sent";
      if (!current()) return "wait";
      const body = item.body, feedback = !item.path;
      try {
        const reply = await services.api(`/functions/v1/photo-feedback${item.path}`, { orgId: scope.library, expectedLibraryOrgId: scope.library, method: "POST", body, signal: abort.signal }) as Record<string, unknown> | null;
        const theirs = content(reply), revision = count(reply?.revision);
        if (feedback ? !theirs || !revision || String(reply!.provenance_id).toLowerCase() !== item.id : !reply?.signal_id) throw new StudioError("invalid-response", "unconfirmed answer");
        // A newer tap during the request is sent next, never overwritten.
        if (storage.getItem(key) !== raw) continue;
        if (!feedback) storage.removeItem(key);
        // A higher stored revision is the newer opinion (§4.1). Only a verdict this
        // tab has just re-keyed onto an existing row is pushed above it.
        else if (revision > body.revision! && !same(theirs!, body)) {
          if (adopting) { save({ ...item, body: { ...body, revision: revision + 1 } }); continue; }
          save({ ...item, state: "sent", body: { ...body, ...theirs, revision } });
        } else save({ ...item, state: "sent" });
        return "sent";
      } catch (error) {
        if (storage.getItem(key) !== raw) continue;
        const conflict = feedback && error instanceof StudioError && error.status === 409 ? error : null, details = conflict?.details ?? {}, existing = details.client_key;
        if (conflict?.code === "feedback_exists" && typeof existing === "string" && /^[A-Za-z0-9:_-]{8,128}$/.test(existing)) {
          // §4.6.7: adopt this person's existing key; resend only when the verdict differs.
          const seen = Math.max(count(details.revision), count(details.revision_count)), theirs = content(details);
          if (seen && theirs && same(theirs, body)) { save({ ...item, state: "sent", body: { ...body, client_key: existing, revision: seen } }); return "sent"; }
          adopting = true; save({ ...item, body: { ...body, client_key: existing, revision: seen + 1 } }); continue;
        }
        if (conflict?.code === "feedback_revision_conflict") { save({ ...item, body: { ...body, revision: body.revision! + 1 } }); continue; }
        const outcome = classify(error);
        // §4.6.5/6: a refused item is not resent, and a key bound to another image is never reused.
        if (outcome === "dropped") save({ ...item, state: "dropped", body: conflict?.code === "feedback_key_conflict" ? { ...body, client_key: newKey(), revision: 1 } : body });
        return outcome;
      }
    }
    return "wait";
  }
  function flush(): Promise<void> {
    if (running) { again = true; return running; }
    cancel();
    return running = (async () => {
      let retry = false, stuck = false;
      do {
        again = false;
        for (const key of queuedFeedback(storage, scope)) {
          if (!current()) return;
          const outcome = await deliver(key);
          stuck ||= outcome === "wait";
          // One transport failure means the rest would fail too; wait for the retry.
          if (retry = outcome === "retry") break;
        }
      } while (again && !retry && current());
      failures = retry || stuck ? failures + 1 : 0;
      if (retry && current() && navigator.onLine !== false) cancel = schedule(Math.min(300_000, 2_500 * 2 ** failures), () => void flush());
    })().catch(() => { /* Items stay queued for the next trigger. */ }).finally(() => { running = null; notify(); });
  }
  return {
    entry: (provenance: string) => load(storage, scope, scoped(scope) + provenance.toLowerCase()),
    /** True while a queued item is undelivered after an attempt, until a pass delivers everything. */
    waiting: () => failures > 0,
    subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; },
    submit(input: Parameters<typeof recordFeedback>[2]) { const item = recordFeedback(storage, scope, input); notify(); void flush(); return item; },
    /** Never throws: a signal must not change the action it follows. */
    signal(provenance: string, signal: SignalName) {
      try { if (recordSignal(storage, scope, provenance, signal)) void flush(); } catch { /* Signals are best effort. */ }
    },
    flush,
    /** Browser only: flush now, on reconnect and whenever the tab is shown again. */
    start() {
      const online = () => void flush(), visible = () => { if (document.visibilityState === "visible") void flush(); };
      addEventListener("online", online); document.addEventListener("visibilitychange", visible);
      abort.signal.addEventListener("abort", () => { removeEventListener("online", online); document.removeEventListener("visibilitychange", visible); });
      void flush();
    },
    dispose() { abort.abort(); cancel(); listeners.clear(); },
  };
}
