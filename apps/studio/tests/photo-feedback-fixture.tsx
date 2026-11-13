import { createRoot } from "react-dom/client";
import type { Session } from "@supabase/auth-js";
import CreativeWorkspace from "../src/features/creative/CreativeWorkspace";
import PhotoFeedbackReport from "../src/features/admin/PhotoFeedbackReport";
import { createStudioServices, type StudioAuth, type StudioServices } from "../src/data/services";
import "../src/styles.css";
import "../src/design/studio.css";
import "../src/features/creative/creative.css";

// Isolated fixture with synthetic ids only: no hosted, provider or paid call.
// Photo feedback and the admin report go through the real Studio transport over
// HTTP to the local fixture server, so browser offline mode really cuts them off.
// Everything else the photo workspace needs is answered in-page, in the shapes
// tests/creative-fixture.tsx already uses.
const ACTOR = "11111111-1111-4111-8111-1111111111f1", ORG = "22222222-2222-4222-8222-2222222222f1", LISTING = "33333333-3333-4333-8333-3333333333f1";
const OUTPUTS = ["77777777-7777-4777-8777-0000000000a1", "77777777-7777-4777-8777-0000000000a2"];
const session = { access_token: "closed-feedback-browser-fixture", refresh_token: "closed-fixture-refresh", expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
  token_type: "bearer", user: { id: ACTOR, aud: "authenticated", created_at: "2026-10-17T00:00:00Z", app_metadata: {}, user_metadata: {} } } as Session;
const auth: StudioAuth = { getSession: async () => ({ data: { session }, error: null }), refreshSession: async () => ({ data: { session }, error: null }),
  signInWithOAuth: async () => ({ error: null }), signOut: async () => ({ error: null }), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) };
const real = createStudioServices({ supabaseUrl: location.origin, publishableKey: "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY", redirectTo: `${location.origin}/` }, { auth });
const workspace = await real.loadWorkspace(undefined, ORG), listings = await real.listListings(ORG);

const png = (color: string) => { const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 600; const draw = canvas.getContext("2d")!;
  draw.fillStyle = color; draw.fillRect(0, 0, 800, 600); draw.fillStyle = "#ffffff"; draw.fillRect(80, 120, 260, 300); return canvas.toDataURL("image/png").split(",")[1]!; };
const edited = [png("#3c8d5a"), png("#d9822b")], calls: { path: string; method: string; body: any }[] = [], tickets = new Map<string, any>();
let generations = 0, uploads = 0;
async function fake(path: string, options: any): Promise<unknown> {
  const method = options.method ?? "GET", body = options.body;
  calls.push({ path, method, body });
  if (options.orgId !== ORG) throw new Error("Wrong organization");
  if (path.includes("studio/documents?")) return { document: null };
  if (path.includes("studio/listing-state?")) return { org_id: ORG, listing_id: LISTING, assets: [], jobs: [], renders: [], photos: [], chapters: [], next_offset: null };
  if (path.includes("studio/creative-results?")) return { results: [], next_offset: null };
  if (path.endsWith("/ai-photo-v2")) { const index = generations++; return { image_b64: edited[index], mime: "image/png", disclosure: "Synthetic fixture: edited with AI. The original is kept.", provenance: { id: OUTPUTS[index], recorded: true } }; }
  if (path === "/functions/v1/uploads" && method === "POST") {
    const id = `88888888-8888-4888-8888-${String(++uploads).padStart(12, "0")}`, ticket = { asset_id: id, storage_key: `renders/${ORG}/${LISTING}/${body.role}-${id}.png`, uploaded: false, mode: "single", put_url: `https://uploads.rendprop.com/v2/${id}?signature=fixture` };
    tickets.set(id, ticket); return ticket;
  }
  if (/\/uploads\/[^/]+\/complete$/.test(path)) { const id = path.split("/").at(-2)!; return { ...tickets.get(id), id, listing_id: LISTING, uploaded: true }; }
  if (path.includes("me/compliance/") && method === "PATCH") return { ok: true };
  if (path.endsWith("studio/photos") && method === "POST") return { ok: true, photo: { id: body.asset_id, listing_id: LISTING } };
  throw new Error(`Unexpected fixture API ${method} ${path}`);
}
const services = { ...real, api: (path: string, options: any) => path.startsWith("/functions/v1/photo-feedback") ? real.api(path, options) : fake(path, options),
  upload: async () => ({ etag: '"fixture-receipt"' }), listMedia: async () => ({ orgId: ORG, listingId: LISTING, photos: [], videos: [], nextOffset: null, unavailableCount: 0 }) } as unknown as StudioServices;
Object.assign(window, { feedbackFixture: { calls: () => structuredClone(calls), edited: () => [...edited], outputs: () => [...OUTPUTS], actor: ACTOR, library: ORG } });
createRoot(document.getElementById("root")!).render(<div className="studio-shell" style={{ display: "block" }}><main style={{ padding: 24 }}>
  {new URLSearchParams(location.search).get("view") === "report" ? <PhotoFeedbackReport services={real} workspace={workspace} />
    : <CreativeWorkspace services={services} workspace={workspace} listings={listings} onChanged={() => {}} />}
</main></div>);
