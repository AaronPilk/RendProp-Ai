import { useState } from "react";
import { createRoot } from "react-dom/client";
import BusinessWorkspace, {type BusinessSectionRequest} from "../src/features/business/BusinessWorkspace";
import type { StudioServices } from "../src/data/services";
import type { Workspace, Listing } from "../src/data/contracts";
import "../src/styles.css";

const user = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", listing = "33333333-3333-4333-8333-333333333333", id = "44444444-4444-4444-8444-444444444444";
const calls: { path: string; method: string; body: unknown }[] = [];
const workspace: Workspace = { user: { id: user, email: "agent@example.invalid", name: "Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 1, leadsNew: 1, renders: 1 } };
const listings: Listing[] = [{ id: listing, orgId: org, spaceType: "real_estate", address: "10 Oak Street", tagline: "", agentId: user, details: {allow_indexing:"true"}, status: "ready", createdAt: "2026-09-14T12:00:00Z", mainPhotoKey: null, beds: 3, baths: 2, sqft: 2000, priceCents: null }];
const lead = { id, listing_id: listing, name: "Alex Buyer", email: "alex@example.invalid", phone: "+15551112222", message: "Can I see the garden?", listing_address: "10 Oak Street", source: "tour", status: "new", synced_crm: false, created_at: "2026-09-14T12:00:00Z" };
const prefs = { lead_received: true, render_ready: true, upload_stuck: false, free_week_ending: true, allowance_low: true, first_tour_nudge: false, muted_until: null };
const meters = { renders: 1, photo_edits: 2, reels: 3, aerials: 4, drone: 5 };
const me = { user: { id: user }, org: { id: org, name: "Fixture office", handle: "office", space_type: "real_estate", brand_kit: { name: "Agent" } as Record<string, unknown> }, usage: { by_feature: meters, caps: meters, windows: Object.fromEntries(Object.keys(meters).map((k) => [k, null])) }, notifications: prefs, entitlement: {}, portfolio_url: "https://rendprop.com/a/office", plan_source: "apple" };
let publicCard: Record<string,string> | null = null;
let portfolioRevision=0, portfolioIds:string[]=[];
let failPersonal=false, mismatchPersonal=false;
const services = { api: async (path: string, options: { method?: string; orgId: string; body?: unknown }) => {
  if (options.orgId !== org) throw new Error("Wrong fixture organization");
  const method = options.method ?? "GET"; calls.push({ path, method, body: options.body });
  if (calls.length > 80) throw new Error("Request loop");
  if (method === "GET" && path.includes("leads?")) return { leads: [structuredClone(lead)] };
  if (method === "PATCH" && path.endsWith(`/leads/${id}`)) { Object.assign(lead, options.body); return { lead: structuredClone(lead) }; }
  if(path.endsWith("me/card")) {
    if(method==="PATCH") { if(failPersonal){failPersonal=false;throw new Error("Synthetic personal card rejection; draft kept.");} const b=options.body as {changes:Record<string,string|null>;expected:Record<string,{present:boolean;value?:string}>};const card=publicCard??{};for(const [key,value] of Object.entries(b.changes)){const e=b.expected[key];if(Object.hasOwn(card,key)!==e.present||e.present&&card[key]!==e.value)throw new Error("409: Your personal card changed; reload before saving.");if(value===null)delete card[key];else card[key]=value;}publicCard=card;}
    if(mismatchPersonal&&method==="PATCH"){mismatchPersonal=false;return{ok:true,user_id:org,space_type:null,public_card:null};}
    const {space_type,...card}=publicCard??{};return{ok:true,user_id:user,space_type:space_type??null,public_card:publicCard?card:null};
  }
  if(path.endsWith("me/portfolio")){if(method==="PUT"){const b=options.body as {expected_revision:number;listing_ids:string[]};if(b.expected_revision!==portfolioRevision&&JSON.stringify(b.listing_ids)!==JSON.stringify(portfolioIds))throw new Error("409: Your portfolio changed; reload before saving.");if(JSON.stringify(b.listing_ids)!==JSON.stringify(portfolioIds)||!portfolioRevision)portfolioRevision++;portfolioIds=b.listing_ids;}return{ok:true,user_id:user,org_id:org,id:portfolioRevision?id:null,revision:portfolioRevision,listing_ids:portfolioIds,portfolio_url:portfolioRevision?`https://rendprop.com/a/member-${id}`:null};}
  if (path === "/functions/v1/me" && method === "GET") return structuredClone(me);
  if (path.endsWith("me/brand") && method === "PATCH") { Object.assign(me.org.brand_kit, options.body); return { ok: true }; }
  if (path.endsWith("me/notifications") && method === "PATCH") { Object.assign(prefs, options.body); return { ok: true, notifications: structuredClone(prefs) }; }
  if (path === "/functions/v1/team" && method === "GET") return { org_id: org, can_manage: true, seats: { used: 1, allowed: 5 }, members: [{ user_id: user, role: "owner", name: "Agent", email: "agent@example.invalid", is_you: true }], invites: [] };
  if (path.endsWith("team/invites") && method === "POST") return { code: "ABCD-EFGH-JKLM", email: (options.body as { email?: string }).email ?? null, expires_at: "2026-09-21T00:00:00Z" };
  if (path.includes("me/compliance?") && method === "GET") return { org_id: org, count: 1, truncated: false, rows: [{ id, listing_id: listing, listing_address: "10 Oak Street", label: "Staged living room", kind: "photo", disclosure: "Virtually staged with AI", original_available: true, original_url: "https://example.invalid/original", altered_url: "https://example.invalid/result", created_at: "2026-09-14T12:00:00Z" }] };
  if (path.includes("team/overview") && method === "GET") return { org_id: org, from: "2026-08-15T12:00:00Z", to: "2026-09-14T12:00:00Z", seats: { used: 1, allowed: 5, pending: 0 }, totals: { listings: 1, tours_published: 2, ai_assets_published: 1, members_published_nothing: 0 }, members: [{ user_id: user, name: "Agent", role: "owner", listings: 1, tours_published: 2, ai_assets_published: 1, last_activity_at: "2026-09-14T12:00:00Z" }] };
  throw new Error(`Operation not permitted in fixture: ${method} ${path}`);
}, signOut: async () => {} } as unknown as StudioServices;
function Fixture() {
  const [sectionRequest, setSectionRequest] = useState<BusinessSectionRequest>();
  const [version, setVersion] = useState(0);
  const [role, setRole] = useState<"owner" | "marketing">("owner");
  Object.assign(window, { businessFixture: { calls: () => structuredClone(calls), card: () => structuredClone(publicCard), brand: () => structuredClone(me.org.brand_kit), failPersonal: () => {failPersonal=true;}, mismatchPersonal: () => {mismatchPersonal=true;}, phoneCard: (changes:Record<string,string>) => {publicCard={...publicCard,...changes};}, marketing: () => setRole("marketing"), section: (section: BusinessSectionRequest["section"], id = crypto.randomUUID()) => setSectionRequest({id,section}), refreshWorkspace: () => setVersion(version + 1) } });
  return <div style={{ padding: 30 }}><BusinessWorkspace sectionRequest={sectionRequest} services={services} workspace={{ ...workspace, memberships: [{ ...workspace.memberships[0], role }] }} listings={listings} onChanged={() => {}} /></div>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
