import type { StudioServices } from "../src/data/services";
import type { Workspace, Listing, ListingMedia } from "../src/data/contracts";
export const org = "10000000-0000-4000-8000-000000000001", listingA = "20000000-0000-4000-8000-000000000002", listingB = "20000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004";
export const ids = { plain: "30000000-0000-4000-8000-000000000001", altered: "30000000-0000-4000-8000-000000000002", original: "30000000-0000-4000-8000-000000000003", missing: "30000000-0000-4000-8000-000000000004", video: "30000000-0000-4000-8000-000000000005", blocked: "30000000-0000-4000-8000-000000000006" };
export const workspace: Workspace = { user: { id: user, email: "fixture@example.invalid", name: "Fixture Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: null, spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 2, leads: 0, leadsNew: 0, renders: 0 } };
export const listings: Listing[] = [listingA, listingB].map((id, index) => ({ id, orgId: org, address: index ? "20 Maple Avenue" : "10 Oak Street", tagline: index ? "Second property" : 'A bright home <script>alert("unsafe")</script>', spaceType: "real_estate", details: { internal_secret: "MUST-NOT-EXPORT", internal_url: "https://fixture.invalid/?access_token=secret" }, status: "ready", createdAt: "2026-09-22T12:00:00Z", mainPhotoKey: null, beds: 3, baths: 2, sqft: 2000, priceCents: 45000000 }));
export const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="), char => char.charCodeAt(0));
export function signedURL(id: string, filename: string) {
  const issued = new Date(Math.floor(Date.now() / 1000) * 1000), stamp = issued.toISOString().replace(/[-:]/g, "").replace(/\.000/, "");
  const params = new URLSearchParams({ "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": "fixture", "X-Amz-Date": stamp, "X-Amz-Expires": "600", "X-Amz-SignedHeaders": "host", "X-Amz-Signature": "a".repeat(64) });
  return { url: `https://${"a".repeat(32)}.r2.cloudflarestorage.com/rendprop-renders/renders/${org}/${id}/${filename}?${params}`, expiresAt: new Date(issued.getTime() + 599000).toISOString() };
}
export function kitFixture() {
  const calls: { path: string; method: string }[] = [], listeners = new Set<() => void>(); let version = 1, currentUser = user;
  const snapshot = () => ({ status: "signed-in", identityVersion: version, identity: { userId: currentUser, isAnonymous: false } });
  const photo = (id: string, asset: string, staged: boolean) => ({ id: asset, listingId: id, ...signedURL(id, `${asset}.png`), caption: staged ? "Virtually staged / AI-altered photo" : "Saved kitchen caption", isStaged: staged, isAltered: staged, originalUrl: staged && asset !== ids.missing ? signedURL(id, `${ids.original}.png`).url : staged ? null : signedURL(id, `${asset}.png`).url, sort: asset === ids.plain ? 0 : 1 });
  const media = (id: string): ListingMedia => ({ orgId: org, listingId: id, photos: id === listingA ? [photo(id, ids.plain, false), photo(id, ids.altered, true), photo(id, ids.missing, true)] : [], videos: [], nextOffset: null, unavailableCount: 0 });
  const state = (id: string) => ({ org_id: org, listing_id: id, assets: id === listingA ? [ids.video, ids.blocked].map(asset => ({ id: asset, listing_id: id, storage_key: `renders/${org}/${id}/${asset}.mp4`, kind: "video", bucket: "renders", uploaded: true, duration_s: 1, bytes: 100, qc_required: true, qc_publishable: asset === ids.video, created_at: "2026-09-22T12:00:00Z" })) : [], photos: media(id).photos.map(row => ({ id: row.id, listing_id: id, original_key: row.isStaged ? row.originalUrl ? `renders/${org}/${id}/${ids.original}.png` : null : `renders/${org}/${id}/${row.id}.png`, enhanced_key: row.isStaged ? `renders/${org}/${id}/${row.id}.png` : null, caption: row.caption, is_staged: row.isStaged, is_main: false, sort: row.sort, created_at: "2026-09-22T12:00:00Z" })), renders: id === listingA ? [{ id: "50000000-0000-4000-8000-000000000005", listing_id: id, job_id: ids.video, slug: "fixture-live-property", published_at: "2026-09-22T12:00:00Z", duration_s: 1, staged: false, created_at: "2026-09-22T12:00:00Z" }] : [], jobs: [], chapters: [], next_offset: null });
  let holdRead = false, releaseRead: (() => void) | undefined;
  const services = {
    getSnapshot: snapshot, subscribe: (listener: () => void) => { listeners.add(listener); return () => listeners.delete(listener); },
    listListings: async () => structuredClone(listings), listMedia: async (_org: string, id: string) => media(id),
    api: async (path: string, options: { orgId: string; method?: string; signal?: AbortSignal }) => {
      if (options.orgId !== org || options.method && options.method !== "GET") throw new Error("Fixture blocks all mutations and foreign workspaces");
      calls.push({ path, method: options.method ?? "GET" });
      const url = new URL(path, "https://fixture.invalid"), id = url.searchParams.get("listing_id") || url.searchParams.get("key")?.split(":")[1];
      if (path.includes("studio/listing-state?")) { const result = state(id!); if (holdRead) { holdRead = false; await new Promise<void>(resolve => { releaseRead = resolve; }); } return result; }
      if (path.includes("studio/creative-results?")) return { results: id === listingA ? [ids.video, ids.blocked].map(asset => ({ id: asset, listing_id: id, kind: "video", state: "completed", ...{ url: signedURL(id!, `${asset}.mp4`).url, expires_at: signedURL(id!, `${asset}.mp4`).expiresAt }, asset_id: asset, provenance_id: asset, source_asset_id: null, source_url: null, label: asset === ids.video ? "Reviewed office reel" : "Video needing review", disclosure: "Edited in Rendprop Studio from saved sources.", video_kind: "edit", qc_required: true, qc_publishable: asset === ids.video, words: [] })) : [], next_offset: null };
      if (path.includes("studio/documents?")) return { document: id === listingA ? { key: `creative:${id}`, kind: "creative", listing_id: id, revision: 1, payload: { schema: 1, script: "Saved listing script. Private reference https://example.invalid/?access_token=do-not-copy", shots: [], cutaways: [] }, updated_at: "2026-09-22T12:00:00Z" } : null };
      throw new Error(`Unexpected fixture route ${path}`);
    },
  } as unknown as StudioServices;
  return { services, calls, state, media, changeAccount: () => { currentUser = "40000000-0000-4000-8000-000000000009"; version++; listeners.forEach(listener => listener()); }, delayRead: () => { holdRead = true; }, releaseRead: () => releaseRead?.() };
}
