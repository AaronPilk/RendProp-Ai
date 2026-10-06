import { createRoot } from "react-dom/client";
import { useState } from "react";
import ListingWorkflow from "../src/features/listings/ListingWorkflow";
import type { Workspace, Listing } from "../src/data/contracts";
import type { GalleryPhoto } from "../src/features/listings/model";
import { orderedGallery } from "../src/features/listings/model";
import type { StudioServices } from "../src/data/services";
import "../src/styles.css";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", asset = "30000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004", jobId = "50000000-0000-4000-8000-000000000005", renderId = "60000000-0000-4000-8000-000000000006";
const workspace: Workspace = { user: { id: user, email: "fixture@example.invalid", name: "Fixture Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 0, leadsNew: 0, renders: 0 } };
let listings: Listing[] = [{ id: listing, orgId: org, address: "10 Oak Street", tagline: "A bright place to call home", spaceType: "real_estate", details: { imported_nested: { source: "MLS", pending: null }, hours: null, year_built: 1998 }, status: "ready", createdAt: "2026-09-14T12:00:00Z", mainPhotoKey: null, soldAt: null, beds: 3, baths: 2, sqft: 2000, priceCents: 45000000 }];
const fixtureIndustry = new URLSearchParams(window.location.search).get("industry");
if (fixtureIndustry) { workspace.org.spaceType=fixtureIndustry; workspace.memberships[0].spaceType=fixtureIndustry; listings[0].spaceType=fixtureIndustry; listings[0].details={...listings[0].details,capacitySeated:20,bookingUrl:"https://old.fixture.invalid"}; }
const factKeys = { address: "address", tagline: "tagline", space_type: "spaceType", beds: "beds", baths: "baths", sqft: "sqft", price_cents: "priceCents", sold_at: "soldAt", status: "status" } as const;
const wire = (row: Listing) => ({ id: row.id, org_id: row.orgId, address: row.address, tagline: row.tagline, space_type: row.spaceType, details: structuredClone(row.details), status: row.status, created_at: row.createdAt, main_photo_key: row.mainPhotoKey, sold_at: row.soldAt ?? null, beds: row.beds, baths: row.baths, sqft: row.sqft, price_cents: row.priceCents, deleted_at: null });
let failNextFacts = false, holdNextFacts = false, mismatchFacts = false, failReload = false;
let releaseFacts: (() => void) | undefined;
const applyFacts = (row: Listing, changes: Record<string, unknown>): Listing => {
  const updated = { ...row };
  for (const [key, value] of Object.entries(changes)) {
    if (!(key in factKeys)) throw new Error("Unsupported fixture fact");
    (updated as unknown as Record<string, unknown>)[factKeys[key as keyof typeof factKeys]] = value;
  }
  return updated;
};
let assets = [{ id: asset, listing_id: listing, storage_key: `uploads/${org}/${listing}/${asset}.mp4`, kind: "video", bucket: "uploads", uploaded: true, duration_s: 30, bytes: 10, created_at: "2026-09-14T12:00:00Z" }];
let photos: GalleryPhoto[] = [];
let jobs: Record<string, unknown>[] = [], renders: Record<string, unknown>[] = [], chapters: Record<string, unknown>[] = [{asset_id:asset,label:"Entry",t_ms:0,sort:0},{asset_id:asset,label:"Kitchen",t_ms:12000,sort:1}];
const uploads = new Map<string, Record<string, unknown>>();
const calls: { path: string; method: string; body: unknown }[] = [];
const canvas = document.createElement("canvas"); canvas.width = 600; canvas.height = 450;
const g = canvas.getContext("2d")!; g.fillStyle = "#6e54a2"; g.fillRect(0, 0, 600, 450); g.fillStyle = "#eee"; g.fillRect(100, 100, 300, 220);
const image = canvas.toDataURL();
const services = {
  getSnapshot: () => ({ status: "signed-in", identityVersion: 1, identity: { userId: user, isAnonymous: false } }),
  listListings: async () => { if (failReload) { failReload = false; throw new Error("Synthetic refresh failed; your field edits are kept."); } return structuredClone(listings); },
  upload: async (_url: string, body: Blob, options: { onProgress?: (n: number, total: number) => void }) => { options.onProgress?.(body.size, body.size); return { etag: "fixture-receipt" }; },
  listMedia: async (_org: string, id: string) => ({ orgId: org, listingId: id, photos: assets.filter((a) => a.listing_id === id && a.kind === "photo" && a.uploaded).map((a) => ({ id: a.id, listingId: id, url: image, expiresAt: "2099-09-14T12:00:00Z", caption: photos.find(photo => photo.id === a.id)?.caption ?? "Property photo", isStaged: false, sort: photos.find(photo => photo.id === a.id)?.sort ?? 0 })), videos: [], nextOffset: null, unavailableCount: 0 }),
  api: async (path: string, options: { method?: string; orgId: string; body?: Record<string, unknown> }) => {
    if (options.orgId !== org) throw new Error("Wrong fixture workspace");
    const method = options.method ?? "GET", body = options.body; calls.push({ path, method, body });
    if (calls.length > 200) throw new Error("Unexpected request loop");
    if (path.endsWith("/client-contact") && method === "GET") return { contact: null };
    if (path.includes("/studio/listing-state?")) { const id = new URL(path, "https://fixture.invalid").searchParams.get("listing_id"); return { org_id: org, listing_id: id, assets: assets.filter((a) => a.listing_id === id), jobs: jobs.filter((a) => a.listing_id === id), renders: renders.filter((a) => a.listing_id === id), photos: photos.filter(photo => photo.listing_id === id), chapters, next_offset: null }; }
    if (path === "/functions/v1/listings" && method === "POST") { const row = applyFacts({ ...listings[0], id: crypto.randomUUID(), details: {}, status: "draft", soldAt: null }, Object.fromEntries(Object.entries(body!).filter(([key]) => key in factKeys))); listings = [...listings, row]; return wire(row); }
    if (path.startsWith("/functions/v1/listings/") && method === "PATCH") throw new Error("426: Upgrade before saving ordinary listing facts.");
    if (path.endsWith("/facts") && method === "PUT") {
      const id = path.split("/").at(-2), current = listings.find(row => row.id === id)!;
      if (failNextFacts) { failNextFacts = false; throw new Error("Synthetic property save failed. Your field edits are kept."); }
      if (holdNextFacts) { holdNextFacts = false; await new Promise<void>(resolve => { releaseFacts = resolve; }); }
      const changes = body!.changes as Record<string, unknown>, expected = body!.expected as Record<string, unknown>;
      if (JSON.stringify(Object.keys(body!).sort()) !== JSON.stringify(["changes", "details_changes", "details_expected", "expected"])) throw new Error("Unexpected facts envelope");
      if (JSON.stringify(Object.keys(changes).sort()) !== JSON.stringify(Object.keys(expected).sort()) || !Object.keys(changes).length && !Object.keys(body!.details_changes as object).length) throw new Error("Every changed fact requires an expected value");
      const detailChanges = body!.details_changes as Record<string,unknown>, detailExpected=body!.details_expected as Record<string,{present:boolean;value:unknown}>;
      if(JSON.stringify(Object.keys(detailChanges).sort())!==JSON.stringify(Object.keys(detailExpected).sort()))throw new Error("Every detail requires exact expected presence/value");
      for(const [key,value]of Object.entries(detailChanges)){const e=detailExpected[key];if((Object.hasOwn(current.details,key)!==e.present||e.present&&JSON.stringify(current.details[key])!==JSON.stringify(e.value))&&!(value===null?!Object.hasOwn(current.details,key):current.details[key]===value))throw new Error("409: This property changed on another device. Your field edits are kept.");}
      const actual = wire(current) as Record<string, unknown>;
      for (const [key, value] of Object.entries(changes)) if (actual[key] !== expected[key] && actual[key] !== value) throw new Error("409: This property changed on another device. Your field edits are kept.");
      const saved = applyFacts(current, changes); saved.details={...saved.details}; for(const [key,value] of Object.entries(detailChanges)){if(value===null)delete saved.details[key];else saved.details[key]=value;} listings = listings.map(row => row.id === id ? saved : row);
      if (mismatchFacts) { mismatchFacts = false; return wire(current); }
      return wire(saved);
    }
    if (path.startsWith("/functions/v1/listings/") && method === "DELETE") throw new Error("Destructive fixture action forbidden");
    if (path.startsWith("/functions/v1/property?")) return { configured: true, facts: { matchedAddress: "10 Oak Street", beds: 4, baths: 2.5, sqft: 2150, lastSalePriceCents: 30000000 } };
    if (path === "/functions/v1/uploads") { const id = crypto.randomUUID(); const bucket = body!.role === "capture" ? "uploads" : "renders"; const row = { id, listing_id: body!.listing_id, storage_key: `${bucket}/${org}/${body!.listing_id}/${id}.${body!.kind === "video" ? "mp4" : "png"}`, kind: body!.kind, bucket, uploaded: false, duration_s: 0, bytes: body!.bytes, created_at: new Date().toISOString() }; uploads.set(id, row); return { asset_id: id, storage_key: row.storage_key, mode: "single", uploaded: false, put_url: "https://uploads.rendprop.com/v2/fixture" }; }
    if (/\/uploads\/.+\/complete$/.test(path)) { const id = path.split("/").at(-2)!; const row = { ...uploads.get(id), uploaded: true }; assets.push(row as typeof assets[number]); return row; }
    if (path.endsWith("/studio/photos")) {
      if (method === "POST") {
        const asset = assets.find(asset => asset.id === body!.asset_id)!;
        if (!photos.some(photo => photo.id === asset.id)) photos.push({ id: asset.id, listing_id: asset.listing_id, original_key: asset.storage_key, enhanced_key: null, caption: String(body!.caption ?? ""), is_staged: false, is_main: false, sort: 0, created_at: asset.created_at });
      } else if (body!.action === "caption") {
        const photo = photos.find(photo => photo.id === body!.photo_id)!;
        if (photo.caption !== body!.caption && photo.caption !== body!.expected_caption) throw new Error("This caption changed on another device. Your text is kept; refresh the photo before saving again.");
        photos = photos.map(row => row.id === photo.id ? { ...row, caption: String(body!.caption) } : row);
      } else if (body!.action === "cover") {
        const photo = photos.find(photo => photo.id === body!.photo_id)!;
        const current = listings.find(item => item.id === photo.listing_id)!;
        const key = photo.enhanced_key || photo.original_key;
        if (current.mainPhotoKey !== body!.expected_main_photo_key && current.mainPhotoKey !== key) throw new Error("The cover changed on another device.");
        photos = photos.map(row => ({ ...row, is_main: row.id === photo.id }));
        listings = listings.map(row => row.id === photo.listing_id ? { ...row, mainPhotoKey: key } : row);
      } else if (body!.action === "reorder") {
        if (JSON.stringify(orderedGallery(photos).map(photo => photo.id)) !== JSON.stringify(body!.expected_order)) throw new Error("The gallery changed on another device. Refresh before reordering.");
        const ids = body!.photo_ids as string[];
        if (ids.length !== photos.length || new Set(ids).size !== photos.length || !photos.every(photo => ids.includes(photo.id))) throw new Error("Incomplete fixture gallery order");
        photos = photos.map(photo => ({ ...photo, sort: ids.indexOf(photo.id) }));
      } else throw new Error("Unexpected gallery fixture action");
      return { ok: true };
    }
    if (path.endsWith("/studio/floorplan")) { listings = listings.map((l) => l.id === body!.listing_id ? { ...l, details: { ...l.details, floorplan_asset_id: body!.asset_id } } : l); return { ok: true }; }
    if (path === "/functions/v1/renders" && method === "POST") { const row = { id: jobId, listing_id: body!.listing_id, capture_asset_id: body!.asset_id, status: "ready", progress: 1, current_step: "ready", tier: body!.tier, error: null, created_at: new Date().toISOString() }; jobs = [row]; return row; }
    if (path.endsWith(`/renders/${jobId}/publish`)) { const row = { id: renderId, listing_id: listing, job_id: jobId, slug: "fixture-tour", published_at: new Date().toISOString(), created_at: new Date().toISOString(), duration_s: 30, staged: false }; renders = [row]; chapters = (body!.chapters as Record<string, unknown>[]).map((c) => ({ ...c, asset_id: asset })); return row; }
    if (path.endsWith(`/renders/${renderId}/chapters`)) { chapters = (body!.chapters as Record<string, unknown>[]).map((c) => ({ ...c, asset_id: asset })); return { ok: true }; }
    if (path.includes("/spatial?")) return { jobs: [] };
    if (path.endsWith("/spatial/capability")) return { enabled: false, reason: "runtime_disabled" };
    throw new Error(`Fixture has no ${method} ${path}`);
  },
} as unknown as StudioServices;
function Fixture() {
  const [items, setItems] = useState(listings), [current, setCurrent] = useState(listing), [mount, setMount] = useState(0);
  Object.assign(window, { listingFixture: { calls: () => structuredClone(calls), snapshot: () => structuredClone({ listings, assets, jobs, renders, chapters, photos }), reopen: () => { setMount(mount + 1); setItems([...listings]); }, phoneCaption: (id: string, caption: string) => { photos = photos.map(photo => photo.id === id ? { ...photo, caption } : photo); }, phoneChange: () => { listings = listings.map(item => item.id === current ? { ...item, tagline: "Updated on the phone" } : item); setItems([...listings]); }, phoneDetails: (changes: Record<string,unknown>) => {listings=listings.map(row=>row.id===current?{...row,details:{...row.details,...changes}}:row);}, phoneFacts: (changes: Record<string, unknown>, refresh = false) => { listings = listings.map(row => row.id === current ? applyFacts(row, changes) : row); if (refresh) setItems([...listings]); }, failNextFacts: () => { failNextFacts = true; }, holdNextFacts: () => { holdNextFacts = true; }, releaseFacts: () => { releaseFacts?.(); releaseFacts = undefined; }, mismatchFacts: () => { mismatchFacts = true; }, failReload: () => { failReload = true; } } });
  return <div style={{ padding: 30 }}><ListingWorkflow key={mount} services={services} workspace={workspace} listings={items} listingId={current} onSelectListing={setCurrent} onChanged={() => setItems([...listings])} /></div>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
