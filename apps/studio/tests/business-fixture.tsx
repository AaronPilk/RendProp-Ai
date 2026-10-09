import { useState } from "react";
import { createRoot } from "react-dom/client";
import BusinessWorkspace, {type BusinessSectionRequest} from "../src/features/business/BusinessWorkspace";
import type { StudioServices } from "../src/data/services";
import type { Workspace, Listing } from "../src/data/contracts";
import "../src/styles.css";

const user = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", listing = "33333333-3333-4333-8333-333333333333", id = "44444444-4444-4444-8444-444444444444";
const teamPersona = new URLSearchParams(window.location.search).get("teamPersona");
if (teamPersona !== null && !["delegated-owner", "invited-agent"].includes(teamPersona)) throw new Error("Unknown isolated Team fixture persona");
const privateOrg = "55555555-5555-4555-8555-555555555555", agent = "66666666-6666-4666-8666-666666666666";
const contentOrg = teamPersona ? privateOrg : org;
let serverRole: "owner" | "agent" | "marketing" = teamPersona === "invited-agent" ? "agent" : "owner";
const calls: { path: string; method: string; body: unknown; orgId: string }[] = [];
const workspace: Workspace = { user: { id: user, email: "agent@example.invalid", name: "Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 1, leadsNew: 1, renders: 1 } };
if (teamPersona) {
  workspace.org = { ...workspace.org, id: privateOrg, name: "Agent’s listings" };
  workspace.libraryOrgId = privateOrg; workspace.ownOrgId = teamPersona === "delegated-owner" ? org : privateOrg;
  workspace.billingOrgId = org; workspace.servingOrgId = org; workspace.canSwitchAgentLibraries = teamPersona === "delegated-owner";
  const privateLibrary = { orgId: privateOrg, orgName: "Agent’s listings", role: teamPersona === "delegated-owner" ? "team_owner" as const : "owner" as const, spaceType: "real_estate" as const, accessMode: teamPersona === "delegated-owner" ? "team_owner" as const : "own" as const, libraryOwnerUserId: teamPersona === "delegated-owner" ? agent : user, billingOrgId: org, canRead: true, canWrite: true, canManageSubscription: false };
  workspace.memberships = teamPersona === "delegated-owner" ? [
    { orgId: org, orgName: "Fixture Team", role: "owner", spaceType: "real_estate", accessMode: "own", libraryOwnerUserId: user, billingOrgId: org, canRead: true, canWrite: true, canManageSubscription: true }, privateLibrary,
  ] : [privateLibrary];
}
const listings: Listing[] = [{ id: listing, orgId: org, spaceType: "real_estate", address: "10 Oak Street", tagline: "", agentId: user, details: {allow_indexing:"true"}, status: "ready", createdAt: "2026-09-14T12:00:00Z", mainPhotoKey: null, beds: 3, baths: 2, sqft: 2000, priceCents: null }];
const lead = { id, listing_id: listing, name: "Alex Buyer", email: "alex@example.invalid", phone: "+15551112222", message: "Can I see the garden?", listing_address: "10 Oak Street", source: "tour", status: "new", synced_crm: false, created_at: "2026-09-14T12:00:00Z" };
const prefs = { lead_received: true, render_ready: true, upload_stuck: false, free_week_ending: true, allowance_low: true, first_tour_nudge: false, muted_until: null };
const meters = { renders: 1, photo_edits: 2, reels: 3, aerials: 4, drone: 5 };
const me = { user: { id: user }, org: { id: org, name: "Fixture office", handle: "office", space_type: "real_estate", brand_kit: { name: "Agent" } as Record<string, unknown> }, usage: { by_feature: meters, caps: meters, windows: Object.fromEntries(Object.keys(meters).map((k) => [k, null])) }, notifications: prefs, entitlement: {}, portfolio_url: "https://rendprop.com/a/office", plan_source: "apple" };
let publicCard: Record<string,string> | null = null;
let portfolioRevision=0, portfolioIds:string[]=[];
let failPersonal=false, mismatchPersonal=false;
let trialUsage: unknown = null;
let servingActivation: unknown = undefined;
let accountPlan: string | undefined;
let accountExpiry: string | undefined;
const services = { api: async (path: string, options: { method?: string; orgId: string; body?: unknown }) => {
  if (options.orgId !== contentOrg) throw new Error("Wrong fixture content library");
  const method = options.method ?? "GET"; calls.push({ path, method, body: options.body, orgId: options.orgId });
  if (calls.length > 80) throw new Error("Request loop");
  if (method === "GET" && path.includes("leads?")) return { leads: [structuredClone(lead)] };
  if (method === "PATCH" && path.endsWith(`/leads/${id}`)) { Object.assign(lead, options.body); return { lead: structuredClone(lead) }; }
  if(path.endsWith("me/card")) {
    if(method==="PATCH") { if(failPersonal){failPersonal=false;throw new Error("Synthetic personal card rejection; draft kept.");} const b=options.body as {changes:Record<string,string|null>;expected:Record<string,{present:boolean;value?:string}>};const card=publicCard??{};for(const [key,value] of Object.entries(b.changes)){const e=b.expected[key];if(Object.hasOwn(card,key)!==e.present||e.present&&card[key]!==e.value)throw new Error("409: Your personal card changed; reload before saving.");if(value===null)delete card[key];else card[key]=value;}publicCard=card;}
    if(mismatchPersonal&&method==="PATCH"){mismatchPersonal=false;return{ok:true,user_id:org,space_type:null,public_card:null};}
    const {space_type,...card}=publicCard??{};return{ok:true,user_id:user,space_type:space_type??null,public_card:publicCard?card:null};
  }
  if(path.endsWith("me/portfolio")){if(method==="PUT"){const b=options.body as {expected_revision:number;listing_ids:string[]};if(b.expected_revision!==portfolioRevision&&JSON.stringify(b.listing_ids)!==JSON.stringify(portfolioIds))throw new Error("409: Your portfolio changed; reload before saving.");if(JSON.stringify(b.listing_ids)!==JSON.stringify(portfolioIds)||!portfolioRevision)portfolioRevision++;portfolioIds=b.listing_ids;}return{ok:true,user_id:user,org_id:org,id:portfolioRevision?id:null,revision:portfolioRevision,listing_ids:portfolioIds,portfolio_url:portfolioRevision?`https://rendprop.com/a/member-${id}`:null};}
  if (path === "/functions/v1/me" && method === "GET") return { ...structuredClone(me), plan: accountPlan ?? (trialUsage ? "pro" : workspace.plan), trial_usage: structuredClone(trialUsage), ...(servingActivation === undefined ? {} : { serving_activation: structuredClone(servingActivation) }), plan_expires_at: accountExpiry ?? (trialUsage ? null : "2026-12-05T12:00:00Z"), trial_ends_at: null };
  if (path.endsWith("me/brand") && method === "PATCH") { Object.assign(me.org.brand_kit, options.body); return { ok: true }; }
  if (path.endsWith("me/notifications") && method === "PATCH") { Object.assign(prefs, options.body); return { ok: true, notifications: structuredClone(prefs) }; }
  if (path === "/functions/v1/team" && method === "GET") return { org_id: org, ...(teamPersona ? { actor_id: user, content_org_id: contentOrg } : {}), can_manage: serverRole === "owner", seats: { used: 1, allowed: 5 }, members: [{ user_id: user, role: serverRole, name: "Agent", email: "agent@example.invalid", is_you: true }], invites: [] };
  if (path.endsWith("team/invites") && method === "POST") return { code: "ABCD-EFGH-JKLM", email: (options.body as { email?: string }).email ?? null, expires_at: "2026-09-21T00:00:00Z" };
  if (path.includes("me/compliance?") && method === "GET") return { org_id: org, count: 1, truncated: false, rows: [{ id, listing_id: listing, listing_address: "10 Oak Street", label: "Staged living room", kind: "photo", disclosure: "Virtually staged with AI", original_available: true, original_url: "https://example.invalid/original", altered_url: "https://example.invalid/result", created_at: "2026-09-14T12:00:00Z" }] };
  if (path.includes("team/overview") && method === "GET") return { org_id: org, ...(teamPersona ? { actor_id: user, content_org_id: contentOrg } : {}), from: "2026-08-15T12:00:00Z", to: "2026-09-14T12:00:00Z", seats: { used: 1, allowed: 5, pending: 0 }, totals: { listings: 1, tours_published: 2, ai_assets_published: 1, members_published_nothing: 0 }, members: [{ user_id: user, name: "Agent", role: serverRole, listings: 1, tours_published: 2, ai_assets_published: 1, last_activity_at: "2026-09-14T12:00:00Z" }] };
  throw new Error(`Operation not permitted in fixture: ${method} ${path}`);
}, signOut: async () => {} } as unknown as StudioServices;
function Fixture() {
  const [sectionRequest, setSectionRequest] = useState<BusinessSectionRequest>();
  const [version, setVersion] = useState(0);
  const [role, setRole] = useState<"owner" | "marketing">("owner");
  Object.assign(window, { businessFixture: { calls: () => structuredClone(calls), trial: (value: unknown) => { trialUsage = structuredClone(value); }, activation: (value: unknown, plan?: string, expiresAt?: string) => { servingActivation = structuredClone(value); accountPlan = plan; accountExpiry = expiresAt; }, card: () => structuredClone(publicCard), brand: () => structuredClone(me.org.brand_kit), failPersonal: () => {failPersonal=true;}, mismatchPersonal: () => {mismatchPersonal=true;}, phoneCard: (changes:Record<string,string>) => {publicCard={...publicCard,...changes};}, marketing: () => {serverRole="marketing";setRole("marketing");}, section: (section: BusinessSectionRequest["section"], id = crypto.randomUUID()) => setSectionRequest({id,section}), refreshWorkspace: () => setVersion(version + 1) } });
  return <div style={{ padding: 30 }}><BusinessWorkspace sectionRequest={sectionRequest} services={services} workspace={teamPersona ? workspace : { ...workspace, memberships: [{ ...workspace.memberships[0], role }] }} listings={listings} onChanged={() => {}} /></div>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
