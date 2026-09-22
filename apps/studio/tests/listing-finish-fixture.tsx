import { createRoot } from "react-dom/client";
import { useState } from "react";
import ListingWorkflow from "../src/features/listings/ListingWorkflow";
import type { Workspace, Listing } from "../src/data/contracts";
import type { SessionSnapshot, StudioServices } from "../src/data/services";
import type { Asset } from "../src/features/listings/model";
import "../src/styles.css";
const org = "10000000-0000-4000-8000-000000000001", id = "20000000-0000-4000-8000-000000000002", assetId = "30000000-0000-4000-8000-000000000003", jobId = "40000000-0000-4000-8000-000000000004";
const scenario = new URLSearchParams(location.search).get("scenario") ?? "photos";
const workspace: Workspace = { user: { id: "50000000-0000-4000-8000-000000000005", email: "fixture@example.invalid", name: "Fixture Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: scenario === "readonly" ? "marketing" : "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 0, leadsNew: 0, renders: 0 } };
const listing: Listing = { id, orgId: org, address: "10 Oak Street", tagline: "A bright place to call home", spaceType: "real_estate", details: {}, status: "ready", createdAt: "2026-09-22T12:00:00Z", mainPhotoKey: null, beds: 3, baths: 2, sqft: 2000, priceCents: 45000000 };
const image = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="450"><rect width="600" height="450" fill="#6f665c"/><path d="M80 330V100h440v230" fill="#e7ded0"/><rect x="130" y="150" width="130" height="140" fill="#c6dfda"/></svg>')}`;
const assets: Asset[] = scenario === "empty" ? [] : [{ id: assetId, listing_id: id, storage_key: `renders/${org}/${id}/fixture.jpg`, kind: ["qc", "readonly", "processing", "failed"].includes(scenario) ? "video" : "photo", bucket: "renders", uploaded: true, duration_s: 30, created_at: listing.createdAt, ...(["qc", "readonly"].includes(scenario) ? { qc_required: true, qc_publishable: false, qc_message: "Review property accuracy" } : {}) }];
if (["processing", "failed"].includes(scenario)) assets[0] = { ...assets[0], bucket: "uploads", storage_key: `uploads/${org}/${id}/source.mp4` };
const calls: { path: string; method: string }[] = [];
const session: SessionSnapshot = { status: "signed-in", identityVersion: 1, identity: { userId: workspace.user.id, email: workspace.user.email, isAnonymous: false }, error: null };
const subscribers = new Set<(snapshot: SessionSnapshot) => void>();
const services = {
  getSnapshot: () => session,
  subscribe: (listener: (snapshot: SessionSnapshot) => void) => { subscribers.add(listener); return () => { subscribers.delete(listener); }; },
  api: async (path: string, options: { method?: string; orgId: string }) => {
    calls.push({ path, method: options.method ?? "GET" });
    if (options.method && options.method !== "GET") throw new Error("This fixture forbids all mutations, paid calls and publication");
    if (scenario === "error") throw new Error("Fixture property status is unavailable");
    if (scenario === "loading") return new Promise(() => {});
    if (path.includes("/studio/listing-state?")) return { org_id: org, listing_id: id, assets, photos: [], jobs: ["processing", "failed"].includes(scenario) ? [{ id: jobId, listing_id: id, capture_asset_id: assetId, status: scenario === "processing" ? "rendering" : "failed", progress: .4, tier: "smooth", error: scenario === "failed" ? "The source could not be processed" : null, current_step: "rendering", created_at: listing.createdAt }] : [], renders: scenario === "live" ? [{ id: jobId, listing_id: id, job_id: jobId, slug: "fixture-oak", published_at: listing.createdAt, created_at: listing.createdAt, duration_s: 30, staged: false }] : [], chapters: [], next_offset: null };
    if (path.includes("/spatial?")) return { jobs: [] };
    if (path.endsWith("/spatial/capability")) return { enabled: false, reason: "runtime_disabled" };
    throw new Error(`Unexpected fixture request ${path}`);
  },
  listMedia: async () => ({ orgId: org, listingId: id, photos: assets.filter(asset => asset.kind === "photo").map(asset => ({ id: asset.id, listingId: id, url: image, expiresAt: "2099-01-01T00:00:00Z", caption: "Fixture living room", isStaged: false, sort: 0 })), videos: [], nextOffset: null, unavailableCount: 0 }),
} as unknown as StudioServices;
function Fixture() {
  const [opened, setOpened] = useState("");
  Object.assign(window, { finishFixture: { calls: () => structuredClone(calls) } });
  return <main style={{ padding: 24 }}><p role="status" aria-label="Opened tool">{opened}</p><ListingWorkflow services={services} workspace={workspace} listings={[listing]} listingId={id} onChanged={() => {}} onOpenFeature={(feature, listingId) => setOpened(`${feature}:${listingId}`)} /></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
