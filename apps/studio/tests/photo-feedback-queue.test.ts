import assert from "node:assert/strict";
import test from "node:test";
import type { Session, AuthChangeEvent } from "@supabase/auth-js";
import { createStudioServices, type StudioAuth } from "../src/data/services";
import { content, createPhotoFeedbackQueue, queuedFeedback, recordFeedback, type FeedbackStorage } from "../src/features/creative/photo-feedback-queue";

// Synthetic identities and outputs only; no hosted or paid call is possible here.
const ACTOR = "10000000-0000-4000-8000-0000000000f1", ORG = "20000000-0000-4000-8000-0000000000f1", LISTING = "30000000-0000-4000-8000-0000000000f1";
const P1 = "77777777-7777-4777-8777-000000000001", P2 = "77777777-7777-4777-8777-000000000002", HISTORICAL = "77777777-7777-4777-8777-000000000003";
const SHA1 = "a".repeat(64), SHA2 = "b".repeat(64);
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
const error = (status: number, code: string, details: Record<string, unknown> = {}) => json({ ...details, error: `fixture ${code}`, code }, status);

class MemoryStorage implements FeedbackStorage {
  private items = new Map<string, string>();
  get length() { return this.items.size; }
  key(index: number) { return [...this.items.keys()][index] ?? null; }
  getItem(key: string) { return this.items.get(key) ?? null; }
  setItem(key: string, value: string) { this.items.set(key, String(value)); }
  removeItem(key: string) { this.items.delete(key); }
  keys() { return [...this.items.keys()]; }
}

type Row = { client_key: string; revision: number; revision_count: number; verdict: string; reasons: string[]; note: string | null };
/** In-memory §4.1/§4.2 server: one live verdict per (output, actor), keys bound to one output, revisions in place. */
function contractServer() {
  const rows = new Map<string, Row>(), bound = new Map<string, string>(), signals = new Map<string, { provenance: string; signal: string }>();
  const evidence = new Map<string, string | null>([[P1, SHA1], [P2, SHA2], [HISTORICAL, null]]);
  const requests: { path: string; body: any; orgHeader: string | null }[] = [];
  let mode: "up" | "down" | "lost" = "up", fullConflict = false, countOnly = false;
  function feedback(actor: string, body: any) {
    const provenance = body?.output?.provenance_id, key = body?.client_key;
    if (typeof key !== "string" || !Number.isInteger(body.revision) || !content(body) || body.platform !== "studio") return error(400, "invalid_request");
    if (!evidence.has(provenance)) return error(404, "output_not_found");
    const pinned = evidence.get(provenance);
    if (body.output.output_sha256 && pinned && body.output.output_sha256 !== pinned) return error(409, "output_mismatch");
    const owner = bound.get(`${actor}:${key}`);
    if (owner && owner !== provenance) return error(409, "feedback_key_conflict");
    const id = `${actor}:${provenance}`, row = rows.get(id), next = { verdict: body.verdict, reasons: body.reasons, note: body.note ?? null };
    const reply = (state: string, value: Row) => json({ feedback_id: "f0000000-0000-4000-8000-000000000001", provenance_id: provenance, revision: value.revision, revision_count: value.revision_count,
      state, verdict: value.verdict, reasons: value.reasons, note: value.note, attribution: { basis: pinned ? "evidence" : "provenance_only", evidence_id: null, edit: "stage", provider: null, model: null,
        generation_stage: null, recipe_revision: null, prompt_sha256: null, attempts_known: false } });
    if (!row) { const created = { client_key: key, revision: body.revision, revision_count: 1, ...next }; rows.set(id, created); bound.set(`${actor}:${key}`, provenance); return reply("recorded", created); }
    if (row.client_key !== key) return error(409, "feedback_exists", { client_key: row.client_key, revision_count: row.revision_count, ...(countOnly ? {} : { revision: row.revision }),
      ...(fullConflict ? { verdict: row.verdict, reasons: row.reasons, note: row.note } : {}) });
    if (body.revision === row.revision) return JSON.stringify(next) === JSON.stringify({ verdict: row.verdict, reasons: row.reasons, note: row.note }) ? reply("replayed", row) : error(409, "feedback_revision_conflict");
    if (body.revision < row.revision) return reply("replayed", row);
    Object.assign(row, next, { revision: body.revision, revision_count: row.revision_count + 1 });
    return reply("revised", row);
  }
  function signal(actor: string, body: any) {
    if (!evidence.has(body?.output?.provenance_id)) return error(404, "output_not_found");
    const id = `${actor}:${body.client_key}`, prior = signals.get(id);
    if (prior && prior.provenance !== body.output.provenance_id) return error(409, "feedback_key_conflict");
    if (!prior) signals.set(id, { provenance: body.output.provenance_id, signal: body.signal });
    return json({ signal_id: "a0000000-0000-4000-8000-000000000001", state: prior ? "replayed" : "recorded" });
  }
  return {
    rows, bound, signals, evidence, requests, setMode: (value: typeof mode) => { mode = value; }, conflictWithVerdict: () => { fullConflict = true; }, conflictCountOnly: () => { countOnly = true; },
    handle(path: string, actor: string, body: any, orgHeader: string | null) {
      if (mode === "down") throw new TypeError("Failed to fetch");
      requests.push({ path, body, orgHeader });
      const response = path === "/functions/v1/photo-feedback" ? feedback(actor, body) : path === "/functions/v1/photo-feedback/signal" ? signal(actor, body) : error(404, "not_found");
      if (mode === "lost") throw new TypeError("connection reset after the server committed");
      return response;
    },
  };
}

function fixture(server = contractServer()) {
  let callback: (event: AuthChangeEvent, session: Session | null) => void = () => {};
  const session: Session = { access_token: "closed-feedback-fixture-not-real", refresh_token: "closed-fixture-refresh", expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
    token_type: "bearer", user: { id: ACTOR, aud: "authenticated", created_at: "2026-10-17T00:00:00Z", app_metadata: {}, user_metadata: {} } };
  const auth: StudioAuth = { getSession: async () => ({ data: { session }, error: null }), refreshSession: async () => ({ data: { session }, error: null }), signInWithOAuth: async () => ({ error: null }),
    signOut: async () => ({ error: null }), onAuthStateChange: cb => { callback = cb; return { data: { subscription: { unsubscribe() {} } } }; } };
  const services = createStudioServices({ supabaseUrl: "https://closed-feedback.supabase.co", publishableKey: "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY", redirectTo: "http://localhost:5173/" }, { auth, fetch: async (input, options = {}) => {
    const url = new URL(String(input)), headers = new Headers(options.headers);
    if (url.pathname === "/functions/v1/me/workspaces") return json({ actor_id: ACTOR, own_org_id: ORG, billing_org_id: ORG, active_org_id: ORG, can_switch_agent_libraries: false,
      workspaces: [{ id: ORG, name: "Own library", role: "owner", access_mode: "own", library_owner_user_id: ACTOR, billing_org_id: ORG, can_read: true, can_write: true, can_manage_subscription: true }] });
    if (url.pathname === "/functions/v1/me") return json({ user: { id: ACTOR, email: null, name: null, avatar_url: null }, org: { id: ORG, name: "Library", space_type: "real_estate", handle: null },
      billing: { org_id: ORG, content_org_id: ORG, serving_org_id: ORG, role: "owner", can_manage_subscription: true },
      plan: "free", plan_raw: "free", trial_ends_at: null, plan_expires_at: null, usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 } });
    if (url.pathname === "/functions/v1/listings") return json({ actor_id: ACTOR, listings: [{ id: LISTING, org_id: ORG, library_org_id: ORG, space_type: "real_estate", address: "Synthetic only", tagline: null,
      details: {}, status: "draft", created_at: "2026-10-17T00:00:00Z", deleted_at: null, main_photo_key: null, beds: null, baths: null, sqft: null, price_cents: null }], total: 1, next_offset: null });
    return server.handle(url.pathname, ACTOR, typeof options.body === "string" ? JSON.parse(options.body) : null, headers.get("X-Org-Id"));
  } });
  const storage = new MemoryStorage(), delays: number[] = [], timers: (() => void)[] = [];
  // Like CreativeWorkspace, the queue is created for an already signed-in workspace.
  const f = { services, server, storage, delays, timers, scope: { actor: ACTOR, library: ORG }, queue: null as unknown as ReturnType<typeof createPhotoFeedbackQueue>,
    async open() {
      await services.loadWorkspace(undefined, ORG); await services.listListings(ORG);
      f.queue = createPhotoFeedbackQueue(services, { actor: ACTOR, library: ORG }, storage, (ms, run) => { delays.push(ms); timers.push(run); return () => {}; });
    },
    switchAccount() { callback("SIGNED_IN", { ...session, user: { ...session.user, id: "10000000-0000-4000-8000-0000000000f2" } }); },
    dispose() { f.queue?.dispose(); services.dispose(); } };
  return f;
}
const feedbackPosts = (f: ReturnType<typeof fixture>) => f.server.requests.filter(request => request.path === "/functions/v1/photo-feedback");

test("verdict content is canonical and bounded exactly like the contract", () => {
  assert.deepEqual(content({ verdict: "needs_work", reasons: ["other", "changed_permanent_features"], note: "Window moved" }),
    { verdict: "needs_work", reasons: ["changed_permanent_features", "other"], note: "Window moved" });
  for (const bad of [{ verdict: "useful", reasons: ["other"] }, { verdict: "needs_work", reasons: [] }, { verdict: "needs_work", reasons: ["not_a_reason"] },
    { verdict: "needs_work", reasons: ["other", "other"] }, { verdict: "needs_work", reasons: ["other"], note: "x".repeat(501) }, { verdict: "great", reasons: [] }, null])
    assert.equal(content(bad), null, JSON.stringify(bad));
});

test("feedback is stored before any request; a lost reply is retried with the same key and body into one row", async () => {
  const f = fixture();
  try {
    await f.open();
    f.server.setMode("lost");
    const item = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] });
    // Written synchronously, before the request could start (§4.6.1).
    assert.equal(item.state, "queued"); assert.match(item.body.client_key, /^studio:[0-9a-f-]{36}$/);
    assert.equal(f.storage.getItem(f.storage.keys()[0]), JSON.stringify(item), "the exact item is in storage before any reply");
    await f.queue.flush();
    assert.equal(f.queue.entry(P1)!.state, "queued"); assert.equal(f.queue.waiting(), true); assert.deepEqual(f.delays, [5_000]);
    f.server.setMode("up");
    await f.queue.flush(); await f.queue.flush();
    const posts = feedbackPosts(f);
    assert.equal(posts.length, 2, "one lost attempt and one confirmed retry, nothing more");
    assert.equal(JSON.stringify(posts[0].body), JSON.stringify(posts[1].body), "a retry is byte-identical");
    assert.equal(posts[0].orgHeader, ORG, "the selected library travels as X-Org-Id");
    assert.equal(f.server.rows.size, 1); const row = [...f.server.rows.values()][0];
    assert.equal(row.revision_count, 1); assert.equal(row.client_key, item.body.client_key);
    assert.equal(f.queue.entry(P1)!.state, "sent"); assert.equal(f.queue.waiting(), false);
  } finally { f.dispose(); }
});

test("an unchanged verdict keeps its revision; a change bumps it under the same key and revises the row in place", async () => {
  const f = fixture();
  try {
    await f.open();
    const first = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] }); await f.queue.flush();
    const again = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] }); await f.queue.flush();
    assert.equal(again.body.revision, 1); assert.equal(feedbackPosts(f).length, 1, "no new revision, no request");
    const changed = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "needs_work", reasons: ["other", "moved_or_changed_appliance"], note: "  Fridge moved  " });
    assert.equal(changed.body.revision, 2); assert.equal(changed.body.client_key, first.body.client_key);
    assert.deepEqual(changed.body.reasons, ["moved_or_changed_appliance", "other"]); assert.equal(changed.body.note, "Fridge moved");
    await f.queue.flush();
    assert.equal(f.server.rows.size, 1); const row = [...f.server.rows.values()][0];
    assert.deepEqual([row.revision, row.revision_count, row.verdict], [2, 2, "needs_work"]);
    assert.equal(f.queue.entry(P1)!.state, "sent");
  } finally { f.dispose(); }
});

test("each output gets its own key, and a key is never sent for another image", async () => {
  const f = fixture();
  try {
    await f.open();
    const one = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] });
    const two = f.queue.submit({ provenance_id: P2, output_sha256: SHA2, verdict: "needs_work", reasons: ["visible_visual_artifacts"] });
    await f.queue.flush();
    assert.notEqual(one.body.client_key, two.body.client_key);
    assert.equal(f.server.bound.get(`${ACTOR}:${one.body.client_key}`), P1); assert.equal(f.server.bound.get(`${ACTOR}:${two.body.client_key}`), P2);
    // A stored item copied under another output's key is not readable, so it is never sent.
    const key1 = f.storage.keys().find(key => key.endsWith(P1))!, key2 = key1.replace(P1, P2);
    f.storage.setItem(key2, JSON.stringify({ ...JSON.parse(f.storage.getItem(key1)!), state: "queued" }));
    assert.equal(f.queue.entry(P2), null); assert.deepEqual(queuedFeedback(f.storage, f.scope), []);
    const before = feedbackPosts(f).length; await f.queue.flush(); assert.equal(feedbackPosts(f).length, before);
    // A consistent item that reuses P1's key for P2 is refused by the server and re-keyed locally.
    const forged = { actor: ACTOR, library: ORG, id: P2, path: "", state: "queued", at: Date.now(), body: { ...two.body, client_key: one.body.client_key, revision: 9, verdict: "useful", reasons: [] } };
    f.storage.setItem(key2, JSON.stringify(forged)); await f.queue.flush();
    const refused = f.queue.entry(P2)!;
    assert.equal(refused.state, "dropped"); assert.notEqual(refused.body.client_key, one.body.client_key); assert.equal(refused.body.revision, 1);
    assert.equal([...f.server.rows.values()].find(row => row.client_key === one.body.client_key)!.verdict, "useful");
    assert.equal(f.server.rows.get(`${ACTOR}:${P2}`)!.verdict, "needs_work", "P2 keeps its own verdict");
  } finally { f.dispose(); }
});

test("the pinned output hash refuses a different image, locally and on the server", async () => {
  const f = fixture();
  try {
    await f.open();
    f.queue.submit({ provenance_id: P1, output_sha256: SHA2, verdict: "useful", reasons: [] }); await f.queue.flush();
    assert.equal(f.queue.entry(P1)!.state, "dropped"); assert.equal(f.server.rows.size, 0, "output_mismatch writes nothing");
    assert.throws(() => recordFeedback(f.storage, f.scope, { provenance_id: P1, output_sha256: SHA1, verdict: "needs_work", reasons: ["other"] }), /different image/);
    assert.equal(f.queue.entry(P1)!.body.verdict, "useful", "a refused local change leaves the stored item untouched");
    // Historical outputs have no evidence hash: the verdict is accepted as provenance-only.
    f.queue.submit({ provenance_id: HISTORICAL, output_sha256: SHA1, verdict: "useful", reasons: [] }); await f.queue.flush();
    assert.equal(f.queue.entry(HISTORICAL)!.state, "sent");
  } finally { f.dispose(); }
});

test("feedback_exists adopts the existing key and resends only a different verdict", async () => {
  const f = fixture();
  try {
    await f.open();
    // Another device already holds this person's verdict for P1 under its own key.
    f.server.rows.set(`${ACTOR}:${P1}`, { client_key: "ios:existing-key-0001", revision: 3, revision_count: 2, verdict: "useful", reasons: [], note: null });
    f.server.bound.set(`${ACTOR}:ios:existing-key-0001`, P1);
    const local = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "needs_work", reasons: ["blocked_doorway_or_opening"] });
    await f.queue.flush();
    const stored = f.queue.entry(P1)!, row = f.server.rows.get(`${ACTOR}:${P1}`)!;
    assert.equal(stored.body.client_key, "ios:existing-key-0001"); assert.equal(stored.state, "sent"); assert.equal(stored.body.revision, 4);
    assert.deepEqual([row.client_key, row.revision, row.revision_count, row.verdict], ["ios:existing-key-0001", 4, 3, "needs_work"]);
    assert.equal(f.server.rows.size, 1); assert.equal(f.server.bound.has(`${ACTOR}:${local.body.client_key}`), false, "the new key was never bound");
    assert.deepEqual(feedbackPosts(f).map(post => post.body.client_key), [local.body.client_key, "ios:existing-key-0001"]);
  } finally { f.dispose(); }
  const g = fixture();
  try {
    await g.open();
    g.server.rows.set(`${ACTOR}:${P1}`, { client_key: "ios:existing-key-0002", revision: 2, revision_count: 2, verdict: "useful", reasons: [], note: null });
    g.server.conflictWithVerdict();
    g.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] }); await g.queue.flush();
    assert.equal(feedbackPosts(g).length, 1, "a 409 that shows the same verdict is adopted without a resend");
    assert.deepEqual([g.queue.entry(P1)!.body.client_key, g.queue.entry(P1)!.body.revision, g.queue.entry(P1)!.state], ["ios:existing-key-0002", 2, "sent"]);
    assert.equal(g.server.rows.get(`${ACTOR}:${P1}`)!.revision_count, 2);
  } finally { g.dispose(); }
});

test("offline feedback waits, then flushes exactly once on the online event", async () => {
  const f = fixture(), page = new EventTarget(), doc = Object.assign(new EventTarget(), { visibilityState: "visible" });
  const globals = globalThis as unknown as Record<string, unknown>, saved = ["addEventListener", "removeEventListener", "document"].map(name => globals[name]);
  Object.assign(globals, { addEventListener: page.addEventListener.bind(page), removeEventListener: page.removeEventListener.bind(page), document: doc });
  try {
    await f.open();
    f.server.setMode("down");
    f.queue.start(); await f.queue.flush();
    f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "needs_work", reasons: ["changed_permanent_features"] }); await f.queue.flush();
    assert.equal(f.server.requests.length, 0); assert.equal(f.queue.entry(P1)!.state, "queued"); assert.equal(f.queue.waiting(), true);
    f.server.setMode("up");
    page.dispatchEvent(new Event("online")); await f.queue.flush();
    assert.equal(feedbackPosts(f).length, 1); assert.equal(f.queue.entry(P1)!.state, "sent");
    doc.dispatchEvent(new Event("visibilitychange")); page.dispatchEvent(new Event("online")); await f.queue.flush();
    assert.equal(feedbackPosts(f).length, 1, "later triggers find nothing left to send");
    f.queue.dispose(); f.queue.submit({ provenance_id: P2, output_sha256: SHA2, verdict: "useful", reasons: [] }); page.dispatchEvent(new Event("online")); await f.queue.flush();
    assert.equal(feedbackPosts(f).length, 1, "a disposed queue stops listening and sending");
  } finally {
    ["addEventListener", "removeEventListener", "document"].forEach((name, index) => { globals[name] = saved[index]; });
    f.dispose();
  }
});

test("signals are append-only per output and kind, with a key derived from the output", async () => {
  const f = fixture();
  try {
    await f.open();
    f.queue.signal(P1, "export"); f.queue.signal(P1, "export"); f.queue.signal(P1, "manual_selection");
    await f.queue.flush();
    const posts = f.server.requests.filter(request => request.path.endsWith("/signal"));
    assert.deepEqual(posts.map(post => [post.body.client_key, post.body.signal, post.body.detail]).sort(),
      [[`studio:export:${P1}`, "export", "download"], [`studio:manual_selection:${P1}`, "manual_selection", "gallery_save"]]);
    assert.equal(f.storage.length, 0, "delivered signals leave nothing behind");
    f.queue.signal(P1, "export"); await f.queue.flush();
    assert.equal(f.server.signals.size, 2, "a repeat replays the same key and adds no row");
    assert.equal(f.server.rows.size, 0, "signals never become feedback");
    f.queue.signal("not-a-uuid", "export"); f.queue.signal(P1.toUpperCase(), "accuracy_ack"); await f.queue.flush();
    assert.equal(f.server.signals.get(`${ACTOR}:studio:accuracy_ack:${P1}`)?.provenance, P1);
  } finally { f.dispose(); }
});

test("definitive refusals stop, an unrecognized 404 waits, and another account's session never sends", async () => {
  const f = fixture();
  try {
    await f.open();
    f.queue.submit({ provenance_id: "77777777-7777-4777-8777-0000000000ff", verdict: "useful", reasons: [] }); await f.queue.flush();
    assert.equal(f.queue.entry("77777777-7777-4777-8777-0000000000ff")!.state, "dropped", "output_not_found drops the item");
    f.server.evidence.delete(P2);
    f.queue.signal(P2, "export"); await f.queue.flush(); f.queue.signal(P2, "export"); await f.queue.flush();
    assert.equal(f.server.requests.filter(request => request.body?.output?.provenance_id === P2).length, 1, "a refused signal is kept as refused and not resent");
    const delays = f.delays.length;
    f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] });
    const realHandle = f.server.handle; f.server.handle = () => json({ code: "NOT_FOUND", message: "Requested function was not found" }, 404);
    await f.queue.flush();
    assert.equal(f.queue.entry(P1)!.state, "queued", "a 404 without output_not_found keeps the verdict"); assert.equal(f.delays.length, delays, "and schedules no timer");
    f.server.handle = realHandle;
    f.switchAccount(); const before = f.server.requests.length; await f.queue.flush();
    assert.equal(f.server.requests.length, before, "nothing is sent once the account changed"); assert.equal(f.queue.entry(P1)!.state, "queued");
  } finally { f.dispose(); }
});

test("an adopted verdict lands above a stored revision the 409 did not report", async () => {
  const f = fixture();
  try {
    await f.open();
    // Another device skipped revisions while offline: revision 5, revision_count 1, and its 409 reports only the count.
    f.server.rows.set(`${ACTOR}:${P1}`, { client_key: "ios:skipped-revisions", revision: 5, revision_count: 1, verdict: "useful", reasons: [], note: null });
    f.server.conflictCountOnly();
    f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "needs_work", reasons: ["requested_edit_incomplete"] }); await f.queue.flush();
    const row = f.server.rows.get(`${ACTOR}:${P1}`)!;
    assert.deepEqual([row.client_key, row.revision, row.revision_count, row.verdict], ["ios:skipped-revisions", 6, 2, "needs_work"]);
    assert.deepEqual(feedbackPosts(f).map(post => post.body.revision), [1, 2, 6], "new key, adopted count + 1 (replayed lower), then above the stored revision");
    assert.equal(f.queue.entry(P1)!.state, "sent"); assert.equal(f.queue.entry(P1)!.body.revision, 6);
  } finally { f.dispose(); }
});

test("a late retry never regresses a newer verdict stored under the same key", async () => {
  const f = fixture();
  try {
    await f.open();
    const item = f.queue.submit({ provenance_id: P1, output_sha256: SHA1, verdict: "useful", reasons: [] }); await f.queue.flush();
    // The same key later carried a newer opinion from elsewhere (revision 7); this browser still has revision 1 queued.
    Object.assign(f.server.rows.get(`${ACTOR}:${P1}`)!, { revision: 7, revision_count: 2, verdict: "needs_work", reasons: ["other"], note: "Seen on the phone" });
    const key = f.storage.keys()[0]; f.storage.setItem(key, JSON.stringify({ ...JSON.parse(f.storage.getItem(key)!), state: "queued" }));
    await f.queue.flush();
    const stored = f.queue.entry(P1)!, row = f.server.rows.get(`${ACTOR}:${P1}`)!;
    assert.deepEqual([stored.state, stored.body.revision, stored.body.verdict, stored.body.note, stored.body.client_key], ["sent", 7, "needs_work", "Seen on the phone", item.body.client_key]);
    assert.deepEqual([row.revision, row.revision_count, row.verdict], [7, 2, "needs_work"], "the replayed retry changed nothing on the server");
  } finally { f.dispose(); }
});
