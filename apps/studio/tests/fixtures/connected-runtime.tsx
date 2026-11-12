import { createRoot } from "react-dom/client";
import type { Session, AuthChangeEvent } from "@supabase/supabase-js";
import App from "../../src/App";
import { createStudioServices, type StudioAuth } from "../../src/data";
import "../../src/styles.css";
import "../../src/design/studio.css";

export function mountConnectedFixture({ preview = false }: { preview?: boolean } = {}) {
  // Separately bundled test entry, never imported by src/main.tsx. No real Auth,
  // provider redirect, customer fixture, remote request or secret is used here.
  const A = "11111111-1111-4111-8111-111111111111";
  const B = "22222222-2222-4222-8222-222222222222";
  const ORG = "33333333-3333-4333-8333-333333333333";
  const OTHER = "44444444-4444-4444-8444-444444444444";
  const sharedProperty = !preview && new URLSearchParams(window.location.search).has("sharedProperty");
  const previewName = (org: string) => org === ORG ? "Morgan Realty · Demo" : "Avery’s library · Demo";
  const factsFixture = !preview && new URLSearchParams(window.location.search).has("facts");
  let user = A;
  let mode = "ok";
  let callbacks: (event: AuthChangeEvent, session: Session | null) => void = () => {};
  let release: (() => void) | undefined;
  const documents = new Map<string, unknown>();
  const contacts = new Map<string, Record<string, unknown>>();
  let failContactSave = false;
  let holdContactSave = false;
  let releaseContactSave: (() => void) | undefined;
  let failFactsSave = false, holdFactsSave = false, mismatchFactsReceipt = false;
  let releaseFactsSave: (() => void) | undefined;
  // Team owner A can choose B’s private library; B only receives their own library.
  // Retained legacy rows keep physical ORG IDs while grouping under the private library.
  const listingRows: Record<string, unknown>[] = [A, B].flatMap((actor, actorIndex) => [ORG, OTHER].map((orgId, orgIndex) => ({
    id: `55555555-5555-4555-8555-5555555555${actorIndex}${orgIndex}`,
    org_id: orgId, library_org_id: actor === A ? ORG : OTHER, agent_id: actor, space_type: "real_estate", address: `Isolated property ${actorIndex + 1}-${orgIndex + 1}`,
    tagline: null, details: {}, status: "draft", created_at: "2026-09-22T00:00:00Z", deleted_at: null,
    main_photo_key: null, beds: null, baths: null, sqft: null, price_cents: null,
  }))).filter(row => !(row.agent_id === A && row.org_id === OTHER));
  if (sharedProperty && listingRows.length) {
    const ownerListing = { ...listingRows[0], id:"55555555-5555-4555-8555-555555555501", address:"Owner’s own property" };
    Object.assign(listingRows[0], { agent_id: B, library_org_id: OTHER });
    listingRows.push(ownerListing);
  }
  const ownLibrary = (actor: string) => actor === A ? ORG : OTHER;
  const authorizedLibraries = (actor: string) => actor === A ? [ORG, OTHER] : [OTHER];
  const activeLibraries = new Map([[A, sharedProperty ? OTHER : ORG], [B, OTHER]]);
  const readableListing = (actor: string, row: Record<string, unknown>) => row.agent_id === actor || actor === A && row.agent_id === B && row.library_org_id === OTHER;
  const scopedListing = (actor: string, selected: string, row: Record<string, unknown>) => readableListing(actor, row) && [row.org_id, row.library_org_id].includes(selected);
  if (!preview && new URLSearchParams(window.location.search).has("secondProperty")) listingRows.push({
    ...listingRows[0], id:"66666666-6666-4666-8666-666666666666", address:"Second property for navigation checks",
  });
  if (!preview && new URLSearchParams(window.location.search).has("noProperties")) listingRows.length = 0;
  if (factsFixture && listingRows.length) Object.assign(listingRows[0], { tagline: "", beds: 0, baths: null, sqft: null, price_cents: 0, sold_at: null, details: { floorplan_asset_id: "fixture-office-plan", imported_nested: { null_value: null, number_value: 20 }, hours: null, capacitySeated: 20, allow_indexing: false } });
  if (preview) {
    Object.assign(listingRows[0], { address: "128 Willow Lane", tagline: "Light-filled living by the park", beds: 3, baths: 2, sqft: 2140, price_cents: 62500000, status: "draft" });
    Object.assign(listingRows[1], { address: "24 Harbor View", tagline: "Room to gather, space to unwind", beds: 4, baths: 3, sqft: 2850, price_cents: 81500000 });
    Object.assign(listingRows[2], { address: "6 Cedar Court", tagline: "A quiet place to call home", beds: 2, baths: 2, sqft: 1480, price_cents: 41000000 });
    listingRows.push({ ...listingRows[0], id: "66666666-6666-4666-8666-666666666666", address: "72 Maple Avenue", tagline: "Character, comfort, and a sunny garden", beds: 4, baths: 2.5, sqft: 2670, price_cents: 74500000 });
    listingRows.push({ ...listingRows[0], id: "77777777-7777-4777-8777-777777777777", address: "310 Lakehouse Drive", tagline: "Your next chapter by the water", beds: 3, baths: 2.5, sqft: 2360, price_cents: 69500000 });
  }
  const calls: { path: string; org?: string | null; method: string; body?: unknown }[] = [];
  const session = (): Session => ({
    access_token: "isolated-fixture-not-a-token",
    refresh_token: "isolated-fixture-not-a-refresh-token",
    token_type: "bearer", expires_in: 3600,
    user: { id: user, email: "fixture@example.invalid", is_anonymous: false,
      aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-09-12T00:00:00Z" },
  });
  const auth: StudioAuth = {
    getSession: async () => ({ data: { session: session() }, error: null }),
    refreshSession: async () => ({ data: { session: session() }, error: null }),
    onAuthStateChange(callback) { callbacks = callback; return { data: { subscription: { unsubscribe() {} } } }; },
    async signInWithOAuth() { throw new Error("No provider operation is permitted in this fixture"); },
    async signOut() { callbacks("SIGNED_OUT", null); return { error: null }; },
  };
  const publicCards = new Map<string, Record<string,string>>();
  const brands = new Map<string, Record<string, string>>();
  const workRoles = new Map<string, string>();
  let notifications = { lead_received: true, render_ready: true, upload_stuck: true, free_week_ending: false, allowance_low: true, first_tour_nudge: false, muted_until: null };
  if (preview) publicCards.set(A, { name: "Morgan Taylor", title: "Real estate agent", brokerage: "Morgan Realty · Demo", email: "morgan@example.invalid", space_type: "real_estate" });
  const fetcher: typeof fetch = async (input, options) => {
    const url = new URL(String(input));
    const org = new Headers(options?.headers).get("X-Org-Id") ?? ORG;
    const actor = user;
    if (preview && url.origin !== window.location.origin) throw new Error("Only the synthetic local service is available in this preview.");
    calls.push({ path: url.pathname, org, method: options?.method ?? "GET", ...(options?.body ? { body: JSON.parse(String(options.body)) } : {}) });
    if (url.pathname === "/functions/v1/studio/projects") return Response.json({projects:[]});
    if (url.pathname === "/functions/v1/studio/project-media" && options?.method !== "POST") return Response.json({media:null});
    if (url.pathname === "/functions/v1/studio/media-analysis" && options?.method !== "POST") return Response.json({available:false});
    if ((url.pathname === "/functions/v1/studio/edit-plan" || url.pathname === "/functions/v1/studio/prompt-enhancement") && options?.method !== "POST") return Response.json({available:false,reason:"disabled",supportedOperations:[]});
    if (url.pathname === "/functions/v1/spatial/capability") return Response.json({enabled:false});
    if (url.pathname === "/functions/v1/studio/creative-results") return Response.json({results:[],next_offset:null});
    if (url.pathname === "/functions/v1/studio/presenter/jobs" && options?.method !== "POST") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),quotes:[],jobs:[],runtime:{available:false,code:"enterprise_contract_required",reason:"AI generation is not connected."}});
    if (url.pathname === "/functions/v1/studio/presenter" && options?.method !== "POST") return Response.json({
      org_id:org, listing_id:url.searchParams.get("listing_id"), profiles:[], drafts:[], reference_candidates:[], source_candidates:[],
      permissions:{can_save_profile:true,can_create_draft:true},
      runtime:{available:false,code:"enterprise_contract_required",reason:"AI generation is not enabled. Save your presenter setup or edit original footage."},
    });
    if (calls.length > (preview ? 10000 : 250)) throw new Error("Unexpected request loop");
    if (url.pathname === "/functions/v1/listings" && options?.method === "POST") {
      if (!authorizedLibraries(actor).includes(org)) return Response.json({error:"Foreign library"},{status:403});
      const body = JSON.parse(String(options.body));
      const row = {id:crypto.randomUUID(),org_id:org,library_org_id:org,agent_id:org === ORG ? A : B,space_type:"real_estate",address:"",tagline:null,details:{},status:"draft",created_at:new Date().toISOString(),deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null,...body};
      listingRows.push(row);return Response.json(row,{status:201});
    }
    if (url.pathname.startsWith("/functions/v1/listings/") && options?.method === "PATCH") return Response.json({error:"Upgrade before saving ordinary listing facts."},{status:426});
    if (url.pathname.endsWith("/facts") && options?.method === "PUT") {
      const id = url.pathname.split("/").at(-2)!;
      const row = listingRows.find(row => row.id === id && scopedListing(actor, org, row));
      if (!row) return Response.json({error:"Foreign fixture property"},{status:403});
      if (failFactsSave) { failFactsSave = false; return Response.json({error:"Synthetic save failed"},{status:503}); }
      if (holdFactsSave) await new Promise<void>(resolve => { releaseFactsSave = resolve; });
      const body = JSON.parse(String(options.body)), fields = ["address","tagline","space_type","beds","baths","sqft","price_cents","status","sold_at"];
      if (JSON.stringify(Object.keys(body).sort()) !== JSON.stringify(["changes","details_changes","details_expected","expected"]) || JSON.stringify(Object.keys(body.expected).sort()) !== JSON.stringify(Object.keys(body.changes).sort()) || !Object.keys(body.changes).length || Object.keys(body.changes).some(key => !fields.includes(key)) || Object.keys(body.details_expected).length || Object.keys(body.details_changes).length) return Response.json({error:"Invalid explicit fixture edit"},{status:400});
      const before = structuredClone(row);
      for (const [key,value] of Object.entries(body.changes)) if ((row[key] ?? null) !== body.expected[key] && (row[key] ?? null) !== value) return Response.json({error:"Facts changed"},{status:409});
      Object.assign(row,body.changes);
      if (mismatchFactsReceipt) { mismatchFactsReceipt = false; return Response.json(before); }
      return Response.json(row);
    }
    if (url.pathname.endsWith("/client-contact")) {
      const id = url.pathname.split("/").at(-2)!;
      const property = listingRows.find(row => row.id === id && scopedListing(actor, org, row));
      if (!property) return Response.json({error:"Foreign fixture property"}, {status:403});
      const contactKey = `${property.agent_id}:${property.library_org_id}:${id}`;
      if (options?.method !== "PUT") return Response.json({contact:contacts.get(contactKey) ?? null});
      if (failContactSave) { failContactSave = false; return Response.json({error:"Synthetic contact save failed. Your changes are kept."}, {status:503}); }
      if (holdContactSave) await new Promise<void>(resolve => { releaseContactSave = resolve; });
      const body = JSON.parse(String(options.body)), saved = contacts.get(contactKey);
      if (body.expected_revision !== (saved?.revision ?? 0)) return Response.json({error:"Contact revision changed"}, {status:409});
      const contact = {...body,listing_id:id,revision:Number(body.expected_revision)+1,updated_at:new Date().toISOString()};
      contacts.set(contactKey, contact); return Response.json({contact});
    }
    if (url.pathname === "/functions/v1/studio/listing-state") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),assets:[],photos:[],jobs:[],renders:[],chapters:[],next_offset:null});
    if (url.pathname === "/functions/v1/studio/media") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),photos:[],videos:[],next_offset:null,unavailable_count:0});
    if (url.pathname === "/functions/v1/studio/documents") {
      const body=options?.body ? JSON.parse(String(options.body)) : null;
      const key=body?.key ?? url.searchParams.get("key"); const storageKey=`${actor}:${org}:${key}`;
      if(body) { const existing=documents.get(storageKey) as {revision:number}|undefined;
        if(body.expected_revision!==(existing?.revision??0))return Response.json({error:"Conflict"},{status:409});
        documents.set(storageKey,{...body,revision:(existing?.revision??0)+1,updated_at:new Date().toISOString()});
      }
      return Response.json({document:documents.get(storageKey)??null});
    }
    if (url.pathname === "/functions/v1/me/workspaces") {
      if (mode === "hold") await new Promise<void>((resolve) => {
        const done = () => { options?.signal?.removeEventListener("abort", done); resolve(); };
        release = done;
        options?.signal?.addEventListener("abort", done, { once: true });
      });
      if (mode === "403" || mode === "503") return Response.json({}, { status: Number(mode) });
      return Response.json({ actor_id: actor, own_org_id: ownLibrary(actor), billing_org_id: ORG,
        active_org_id: new Headers(options?.headers).get("X-Org-Id") ?? activeLibraries.get(actor), can_switch_agent_libraries: actor === A,
        workspaces: authorizedLibraries(actor).map(id => ({ id, name: preview ? (brands.get(id)?.org_name ?? previewName(id)) : id === ORG ? "Fixture business" : "Second business", space_type: "real_estate",
          library_owner_user_id: id === ORG ? A : B, role: id === ownLibrary(actor) ? "owner" : "team_owner",
          access_mode: id === ownLibrary(actor) ? "own" : "team_owner", billing_org_id: ORG,
          can_read: true, can_write: true, can_manage_subscription: actor === A && id === ORG })) });
    }
    if (url.pathname === "/functions/v1/me/workspace" && options?.method === "POST") {
      const body = JSON.parse(String(options.body));
      if (!authorizedLibraries(actor).includes(body.org_id)) return Response.json({error:"Foreign library"}, {status:403});
      activeLibraries.set(actor, body.org_id);
      return Response.json({ok:true,org_id:body.org_id});
    }
    if (url.pathname === "/functions/v1/me/card") {
      const card = publicCards.get(actor) ?? {};
      if (options?.method === "PATCH") { const b = JSON.parse(String(options.body)); for (const [key, value] of Object.entries(b.changes)) { const e = b.expected[key]; if (Object.hasOwn(card,key) !== e.present || e.present && card[key] !== e.value) return Response.json({error:"Personal card changed"},{status:409}); if(value===null) delete card[key]; else card[key]=String(value); } publicCards.set(actor,card); }
      const {space_type,...public_card}=card; return Response.json({ok:true,user_id:actor,space_type:space_type??null,public_card:publicCards.has(actor)?public_card:null});
    }
    if (url.pathname === "/functions/v1/me/portfolio") return Response.json({ok:true,user_id:actor,org_id:org,id:null,revision:0,listing_ids:[],portfolio_url:null});
    if (preview && url.pathname === "/functions/v1/me/brand" && options?.method === "PATCH") {
      if (!authorizedLibraries(actor).includes(org)) return Response.json({ error: "Foreign library" }, { status: 403 });
      brands.set(org, { ...brands.get(org), ...JSON.parse(String(options.body)) });
      return Response.json({ ok: true });
    }
    if (preview && url.pathname === "/functions/v1/me/notifications" && options?.method === "PATCH") {
      notifications = { ...notifications, ...JSON.parse(String(options.body)) };
      return Response.json({ notifications });
    }
    if (preview && url.pathname === "/functions/v1/me/profile" && options?.method === "PATCH") {
      const role = JSON.parse(String(options.body)).real_estate_role;
      workRoles.set(actor, role); return Response.json({ user: { id: actor, real_estate_role: role } });
    }
    if (preview && url.pathname === "/functions/v1/leads" && (!options?.method || options.method === "GET")) return Response.json({ leads: [] });
    if (preview && url.pathname === "/functions/v1/ai-voice/voices" && (!options?.method || options.method === "GET")) return Response.json({ voices: [] });
    if (url.pathname === "/functions/v1/me" && (!preview || !options?.method || options.method === "GET")) {
      if (!authorizedLibraries(actor).includes(org)) return Response.json({error:"Foreign library"},{status:403});
      activeLibraries.set(actor,org);
      return Response.json({
        user: { id: actor, name: preview ? actor === A ? "Morgan Taylor" : "Avery Chen" : actor === A ? "  " : "Fixture B", email: "fixture@example.invalid", avatar_url: null, ...(preview ? { real_estate_role: workRoles.get(actor) ?? "agent" } : {}) },
        org: { id: org, name: preview ? (brands.get(org)?.org_name ?? previewName(org)) : org === ORG ? "Fixture business" : "Second business", handle: null, space_type: "real_estate", ...(preview ? { brand_kit: brands.get(org) ?? { name: "Morgan Taylor", title: "Real estate agent", accent: "#7C3AED" } } : {}) },
        billing: { actor_id: actor, content_org_id: org, org_id: ORG, serving_org_id: ORG, can_manage_subscription: actor === A },
        plan: "free", plan_raw: "trial", trial_ends_at: null, plan_expires_at: null,
        usage: { listings: preview ? listingRows.filter(row => row.library_org_id === org).length : 0, leads: 0, leads_new: 0, renders: 0, ...(preview ? { by_feature: { renders: 0, photo_edits: 0, reels: 0, aerials: 0, drone: 0 }, caps: { renders: 0, photo_edits: 0, reels: 0, aerials: 0, drone: 0 }, windows: { renders: null, photo_edits: null, reels: null, aerials: null, drone: null } } : {}) },
        ...(preview ? { notifications, entitlement: { degraded: false }, portfolio_url: null, plan_source: "none" } : {}),
      });
    }
    if (url.pathname === "/functions/v1/listings") {
      if (!authorizedLibraries(actor).includes(org)) return Response.json({error:"Foreign library"},{status:403});
      const offset = Number(url.searchParams.get("offset"));
      if (url.searchParams.get("library") !== "1" || url.searchParams.get("limit") !== "500" || !Number.isSafeInteger(offset) || offset < 0) throw new Error("Missing complete library pagination");
      const selectedRows=listingRows.filter(row=>row.library_org_id===org && readableListing(actor,row));
      return Response.json({ actor_id: actor, org_id: org, listings: selectedRows.slice(offset,offset+500), total:selectedRows.length, next_offset: offset+500<selectedRows.length ? offset+500 : null });
    }
    if (preview) return Response.json({ error: "This action is disabled in the local preview. AI, payments, uploads, publishing, account deletion and provider services are disconnected." }, { status: 503 });
    throw new Error(`Unexpected fixture request: ${url.pathname}`);
  };
  const servicesFactory = () => createStudioServices({
    supabaseUrl: preview ? window.location.origin : "https://studio-isolated-fixture.supabase.co",
    publishableKey: "sb_publishable_ISOLATED_FIXTURE_NOT_REAL",
    redirectTo: `${window.location.origin}/`,
  }, { auth, fetch: fetcher, readTimeoutMs: 5000 });
  Object.assign(window, { studioFixture: {
    setMode(next: string) { mode = next; },
    release() { mode = "ok"; release?.(); release = undefined; },
    switchUser(next: "A" | "B") { user = next === "A" ? A : B; callbacks("SIGNED_IN", session()); },
    failContactSave() { failContactSave = true; },
    holdContactSave() { holdContactSave = true; },
    releaseContactSave() { holdContactSave = false; releaseContactSave?.(); releaseContactSave = undefined; },
    phoneFacts(changes: Record<string, unknown>, id = listingRows[0]?.id) { const row = listingRows.find(row => row.id === id); if (!row) throw new Error("Unknown fixture property"); Object.assign(row, changes); },
    failFactsSave() { failFactsSave = true; },
    holdFactsSave() { holdFactsSave = true; },
    releaseFactsSave() { holdFactsSave = false; releaseFactsSave?.(); releaseFactsSave = undefined; },
    mismatchFactsReceipt() { mismatchFactsReceipt = true; },
    listingRows() { return structuredClone(listingRows); },
    legacyFactsWrite() { return services.api(`/functions/v1/listings/${listingRows[0].id}`, { orgId: ORG, method: "PATCH", body: { address: "Rejected legacy broad write" } }).then(() => ({ accepted: true }), error => ({ accepted: false, status: error.status })); },
    calls() { return calls.slice(); },
  } });
  const services = servicesFactory();
  createRoot(document.getElementById("root")!).render(<App servicesFactory={() => services} />);
}
