import { createRoot } from "react-dom/client";
import type { Session, AuthChangeEvent } from "@supabase/supabase-js";
import App from "../../src/App";
import { createStudioServices, type StudioAuth } from "../../src/data";
import "../../src/styles.css";

// Separately bundled test entry, never imported by src/main.tsx. No real Auth,
// provider redirect, customer fixture, remote request or secret is used here.
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const ORG = "33333333-3333-4333-8333-333333333333";
const OTHER = "44444444-4444-4444-8444-444444444444";
const L1="55555555-5555-4555-8555-555555555555",L2="66666666-6666-4666-8666-666666666666";
let user = A;
let mode = "ok";
let callbacks: (event: AuthChangeEvent, session: Session | null) => void = () => {};
let release: (() => void) | undefined;
const documents = new Map<string, unknown>();
const listingRows: Record<string, unknown>[] = [L1,L2].slice(0,Number(new URL(location.href).searchParams.get("homes")??2)).map((id,i)=>({id,org_id:ORG,library_org_id:ORG,agent_id:A,space_type:"real_estate",address:i?"22 Pine Street":"10 Oak Street",tagline:"A bright new beginning",details:{},status:"ready",created_at:"2026-09-14T12:00:00Z",deleted_at:null,main_photo_key:`renders/${ORG}/${id}/cover.png`,beds:3,baths:2,sqft:2100,price_cents:49000000}));
function mediaRows(listingId:string){
 const now=new Date(),stamp=now.toISOString().replace(/[-:]/g,"").replace(/\.\d{3}Z$/,"Z");
 const expires=new Date(Math.floor(now.getTime()/1000)*1000+600000).toISOString();
 const photo=(i:number)=>{const id=`77777777-7777-4777-8777-${String(i).padStart(12,"0")}`;
 const url=`https://012345678901234567890123456789ab.r2.cloudflarestorage.com/rendprop-renders/renders/${ORG}/${listingId}/${id}.png?${new URLSearchParams({"X-Amz-Algorithm":"AWS4-HMAC-SHA256","X-Amz-Signature":"a".repeat(64),"X-Amz-SignedHeaders":"host","X-Amz-Credential":"isolated-fixture","X-Amz-Date":stamp,"X-Amz-Expires":"600"})}`;
 return {id,listing_id:listingId,url,original_url:url,is_altered:false,is_staged:false,sort:i-1,caption:["Living room","Kitchen","Garden"][i-1],expires_at:expires};};
 return listingId===L1?[photo(1),photo(2),photo(3)]:[];
}
const calls: { path: string; org?: string | null; method:string; body?:unknown }[] = [];
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
const fetcher: typeof fetch = async (input, options) => {
  const url = new URL(String(input));
  const org = new Headers(options?.headers).get("X-Org-Id") ?? ORG;
  const actor = user;
  calls.push({ path: url.pathname, org, method:options?.method??"GET",body:options?.body?JSON.parse(String(options.body)):undefined });
  if (url.pathname === "/functions/v1/spatial/capability") return Response.json({enabled:new URL(location.href).searchParams.get("spatial")==="on"});
  if (calls.length > 600) throw new Error("Unexpected request loop");
  if (url.pathname === "/functions/v1/listings" && options?.method === "POST") {
    const body = JSON.parse(String(options.body));
    const row = {id:crypto.randomUUID(),org_id:org,library_org_id:org,agent_id:actor,space_type:"real_estate",address:"",tagline:null,details:{},status:"draft",created_at:new Date().toISOString(),deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null,...body};
    listingRows.push(row);return Response.json(row,{status:201});
  }
  if (url.pathname.endsWith("/client-contact")) return Response.json({contact:null});
  if (url.pathname === "/functions/v1/studio/listing-state") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),assets:[],photos:mediaRows(url.searchParams.get("listing_id")!).map(p=>({id:p.id,listing_id:p.listing_id,caption:p.caption,is_staged:false,is_main:p.sort===0,sort:p.sort,original_key:`renders/${org}/${p.listing_id}/${p.id}.png`,enhanced_key:null,created_at:"2026-09-14T12:00:00Z"})),jobs:[],renders:[],chapters:[],next_offset:null});
  if (url.pathname === "/functions/v1/studio/media") return Response.json({org_id:org,listing_id:url.searchParams.get("listing_id"),photos:mediaRows(url.searchParams.get("listing_id")!),videos:[],next_offset:null,unavailable_count:0});
  if(url.pathname==="/functions/v1/studio/creative-results")return Response.json({results:[],next_offset:null});
  if(url.pathname==="/functions/v1/studio/projects" && (options?.method??"GET")==="GET")return Response.json({projects:[]});
  if(url.pathname==="/functions/v1/ai-voice/voices")return Response.json({voices:[]});
  if(url.pathname==="/functions/v1/leads")return Response.json({leads:[]});
  if(url.pathname==="/functions/v1/spatial")return Response.json({jobs:[]});
  if(url.pathname==="/functions/v1/spatial/sessions")return Response.json({sessions:[],next_offset:null});
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
    const own = actor === A ? ORG : OTHER;
    return Response.json({ actor_id:actor, own_org_id:own, billing_org_id:own, active_org_id:own, can_switch_agent_libraries:false,
      workspaces:[{ id:own, name:own === ORG ? "Fixture business" : "Second business", space_type:"real_estate", library_owner_user_id:actor,
        role:"owner",access_mode:"own",billing_org_id:own,can_read:true,can_write:true,can_manage_subscription:true }] });
  }
  if (url.pathname === "/functions/v1/me/card") {
    const card = publicCards.get(actor) ?? {};
    if (options?.method === "PATCH") { const b = JSON.parse(String(options.body)); for (const [key, value] of Object.entries(b.changes)) { const e = b.expected[key]; if (Object.hasOwn(card,key) !== e.present || e.present && card[key] !== e.value) return Response.json({error:"Personal card changed"},{status:409}); if(value===null) delete card[key]; else card[key]=String(value); } publicCards.set(actor,card); }
    const {space_type,...public_card}=card; return Response.json({ok:true,user_id:actor,space_type:space_type??null,public_card:publicCards.has(actor)?public_card:null});
  }
  if (url.pathname === "/functions/v1/me/portfolio") return Response.json({ok:true,user_id:actor,org_id:org,id:null,revision:0,listing_ids:[],portfolio_url:null});
  if (url.pathname === "/functions/v1/me") return Response.json({
    user: { id: actor, name: actor === A ? "  " : "Fixture B", email: "fixture@example.invalid", avatar_url: null },
    org: { id: org, name: org === ORG ? "Fixture business" : "Second business", handle: null, space_type: "real_estate",brand_kit:{name:"Jamie Agent",title:"Real estate agent",accent:"#7C3AED"} },
    billing:{content_org_id:org,org_id:org,serving_org_id:org,can_manage_subscription:true},
    notifications:{lead_received:true,render_ready:true,upload_stuck:true,free_week_ending:false,allowance_low:true,first_tour_nudge:false,muted_until:null},entitlement:{degraded:false},portfolio_url:null,plan_source:"apple",
    plan: "free", plan_raw: "trial", trial_ends_at: null, plan_expires_at: null,
    usage: { listings: listingRows.length, leads: 0, leads_new: 0, renders: 0, by_feature:{photo_edits:0,reels:0,aerials:0,drone:0,renders:0},caps:{photo_edits:50,reels:50,aerials:50,drone:50,renders:50},windows:{renders:null,photo_edits:null,reels:null,aerials:null,drone:null} },
  });
  if (url.pathname === "/functions/v1/listings") {
    const own = actor === A ? ORG : OTHER;
    if (org !== own) return Response.json({error:"Foreign library"},{status:403});
    const offset = Number(url.searchParams.get("offset"));
    if (url.searchParams.get("library") !== "1" || url.searchParams.get("limit") !== "500" || !Number.isSafeInteger(offset) || offset < 0) throw new Error("Missing complete library pagination");
    const selectedRows=listingRows.filter(row=>row.library_org_id===org&&row.agent_id===actor);
    return Response.json({actor_id:actor,org_id:org,listings:selectedRows.slice(offset,offset+500),total:selectedRows.length,next_offset:offset+500<selectedRows.length?offset+500:null});
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`);
};
const servicesFactory = () => createStudioServices({
  supabaseUrl: "https://studio-isolated-fixture.supabase.co",
  publishableKey: "sb_publishable_ISOLATED_FIXTURE_NOT_REAL",
  redirectTo: `${window.location.origin}/`,
}, { auth, fetch: fetcher, readTimeoutMs: 5000 });
Object.assign(window, { brandFixture: {
  setMode(next: string) { mode = next; },
  release() { mode = "ok"; release?.(); release = undefined; },
  switchUser(next: "A" | "B") { user = next === "A" ? A : B; callbacks("SIGNED_IN", session()); },
  calls() { return calls.slice(); },
} });
createRoot(document.getElementById("root")!).render(<App servicesFactory={servicesFactory} />);
