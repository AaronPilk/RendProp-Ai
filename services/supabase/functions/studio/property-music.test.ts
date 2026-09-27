import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { handlePropertyMusic } from "./property-music.ts";
import type { StudioContext } from "./context.ts";
import type { ProjectMediaRow } from "./project-media.ts";

const org = "10000000-0000-4000-8000-000000000001", author = "10000000-0000-4000-8000-000000000002", reviewer = "10000000-0000-4000-8000-000000000003", listing = "10000000-0000-4000-8000-000000000004", mediaId = "10000000-0000-4000-8000-000000000005", sha = "a".repeat(64);
type Options = { actor?: string; review?: boolean; copied?: boolean; wrongHash?: boolean; wrongVersion?: boolean; changedAfterSign?: boolean; missing?: boolean; deleting?: boolean; incomplete?: boolean; notAudio?: boolean; denied?: boolean };
function fixture(options: Options = {}) {
  let signs = 0, authorized = 0, rpcCalls = 0;
  const row: ProjectMediaRow = { id: mediaId, actor_id: author, org_id: org, sha256: sha, bytes: 3, mime: options.notAudio ? "video/mp4" : "audio/mpeg", filename: "music.mp3", modified: 0, parts: 1, write_deadline: "2026-09-25", receipts: { "0": { state: options.incomplete ? "claimed" : "complete", bytes: 3, sha256: sha } } };
  function data(table: string, filters: Record<string, unknown>) {
    if (table !== "deletion_requests") assertEquals(filters.org_id, org);
    if (table === "studio_property_music") { assertEquals(filters.listing_id, listing); assertEquals(filters.sha256, sha); return options.missing ? null : { media_id: mediaId }; }
    if (table === "studio_project_media") { assertEquals(filters.id, mediaId); assertEquals(filters.sha256, sha); return row; }
    if (table === "deletion_requests") { assertEquals(filters.user_id, author); return options.deleting ? [{ user_id: author }] : []; }
    if (table === "studio_property_music_copies") return options.copied ? { source_version_id: "version" } : null;
    if (table === "studio_production_versions") { assertEquals(filters.id, "version"); assertEquals(filters.listing_id, listing); return { payload: { draft: { music: { licensed: true, source: { sha256: options.wrongVersion ? "b".repeat(64) : sha } } } } }; }
    if (table === "studio_documents") return { payload: { draft: { music: { licensed: true, source: { sha256: options.wrongHash ? "b".repeat(64) : sha } } } } };
    throw new Error(`Unexpected table ${table}`);
  }
  const admin = { from: (table: string) => {
    const filters: Record<string, unknown> = {};
    const builder = { select: () => builder, eq: (key: string, value: unknown) => { filters[key] = value; return builder; }, neq: () => builder,
      maybeSingle: async () => ({ data: data(table, filters), error: null }), limit: async () => ({ data: data(table, filters), error: null }) };
    return builder;
  }, rpc: (name: string, args: Record<string, unknown>) => ({ abortSignal: async () => {
    rpcCalls++;
    if (name === "studio_property_music_attach") { assertEquals(args, { p_actor: options.actor ?? author, p_org: org, p_listing: listing, p_sha256: sha }); return { data: { media_id: mediaId }, error: null }; }
    assertEquals(name, "studio_production_review"); assertEquals(args.p_document_user_id, author); assertEquals(args.p_actor, options.actor ?? author);
    return { data: { document: { revision: options.changedAfterSign && signs ? 3 : 2, payload: { draft: { music: { licensed: true, source: { sha256: options.wrongHash ? "b".repeat(64) : sha, size: 3 } } } } }, source_revision: 2, review: { status: "in_review", submitted_at: "2026-09-24" } }, error: null };
  } }) };
  const context = { admin, userId: options.actor ?? author, orgId: org, authorizeListing: async (id: string) => { assertEquals(id, listing); if (options.denied) throw new HttpError(403, "Forbidden"); authorized++; } } as unknown as StudioContext;
  const sign = async (candidate: ProjectMediaRow) => { assertEquals(candidate.id, mediaId); signs++; return { id: mediaId } as Awaited<ReturnType<typeof import("./project-media.ts").projectMediaManifest>>; };
  return { context, sign, counts: () => ({ signs, authorized, rpcCalls }) };
}
function get() { return new Request(`https://fixture.invalid/studio/property-music?listing_id=${listing}&sha256=${sha}`); }
function review() { return new Request("https://fixture.invalid/studio/production-review/music", { method: "POST", body: JSON.stringify({ listing_id: listing, sha256: sha, key: `edit:${listing}`, document_user_id: author, expected_document_revision: 2 }) }); }
Deno.test("music restore signs own complete audio only after property authorization and rechecks before return", async () => {
  const f = fixture(); const result = await handlePropertyMusic(get(), f.context, f.sign); assertEquals(result.status, 200); assertEquals(f.counts(), { signs: 1, authorized: 2, rpcCalls: 0 });
});
Deno.test("a guessed music hash cannot read another private account's audio without a copied current draft", async () => {
  for (const options of [{ actor: reviewer }, { actor: reviewer, copied: true, wrongHash: true }, { actor: reviewer, copied: true, wrongVersion: true }]) { const f = fixture(options); await assertRejects(() => handlePropertyMusic(get(), f.context, f.sign), HttpError); assertEquals(f.counts().signs, 0); }
  const copied = fixture({ actor: reviewer, copied: true }); assertEquals((await handlePropertyMusic(get(), copied.context, copied.sign)).status, 200);
});
Deno.test("music review signs only exact selected immutable revision, then discards after concurrent change", async () => {
  const accepted = fixture({ actor: reviewer }); assertEquals((await handlePropertyMusic(review(), accepted.context, accepted.sign)).status, 200); assertEquals(accepted.counts().rpcCalls, 2);
  const wrong = fixture({ actor: reviewer, wrongHash: true }); await assertRejects(() => handlePropertyMusic(review(), wrong.context, wrong.sign), HttpError); assertEquals(wrong.counts().signs, 0);
  const changed = fixture({ actor: reviewer, changedAfterSign: true }); await assertRejects(() => handlePropertyMusic(review(), changed.context, changed.sign), HttpError, "changed"); assertEquals(changed.counts().signs, 1);
});
Deno.test("missing, revoked, incomplete, nonaudio or unauthorized music never gets a capability", async () => {
  for (const options of [{ missing: true }, { deleting: true }, { incomplete: true }, { notAudio: true }, { denied: true }]) { const f = fixture(options); await assertRejects(() => handlePropertyMusic(get(), f.context, f.sign), HttpError); assertEquals(f.counts().signs, 0); }
});
Deno.test("music attachment requires explicit permission declaration and returns no arbitrary private media URL", async () => {
  const f = fixture(); const body = { listing_id: listing, sha256: sha };
  await assertRejects(() => handlePropertyMusic(new Request("https://fixture.invalid/studio/property-music", { method: "POST", body: JSON.stringify(body) }), f.context, f.sign), HttpError);
  assertEquals(f.counts().rpcCalls, 0);
  const result = await handlePropertyMusic(new Request("https://fixture.invalid/studio/property-music", { method: "POST", body: JSON.stringify({ ...body, licensed: true }) }), f.context, f.sign);
  assertEquals(await result.json(), { attached: true, sha256: sha }); assertEquals(f.counts().signs, 0);
});
