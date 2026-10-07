// Capture the actual deployed handlers and stub only Auth/PostgREST transport.
// No socket, provider, real account, or object-storage network call is allowed.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002";
const renderId = "30000000-0000-4000-8000-000000000003", asset = "40000000-0000-4000-8000-000000000004";
const user = "50000000-0000-4000-8000-000000000005", jobId = "60000000-0000-4000-8000-000000000006";
const galleryId = "70000000-0000-4000-8000-000000000007", resultId = "80000000-0000-4000-8000-000000000008";
const olderGalleryId="70000000-0000-4000-8000-000000000017";
const portfolioId="a0000000-0000-4000-8000-00000000000a";
const contactId="90000000-0000-4000-8000-000000000009";
const contactKey=`renders/${org}/${listing}/contact-${contactId}.jpg`;
const prefix = `renders/${org}/${listing}`, key = `${prefix}/finished.mp4`, altered = `${prefix}/altered.mp4`, galleryKey = `${prefix}/gallery-test.jpg`;
const olderGalleryKey=`${prefix}/gallery-old-staged.jpg`;
for (const [name, value] of Object.entries({ SUPABASE_URL: "https://media-privacy-fixture.invalid", SUPABASE_ANON_KEY: "synthetic-public", SUPABASE_SERVICE_ROLE_KEY: "synthetic-service", CLOUDFLARE_ACCOUNT_ID: "media-fixture", R2_ACCESS_KEY_ID: "synthetic-access", R2_SECRET_ACCESS_KEY: "synthetic-secret", R2_PUBLIC_BASE_URL: "https://media-fixture.invalid" })) Deno.env.set(name, value);
let captured!: (req: Request) => Promise<Response>;
const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (fn: typeof captured) => { captured = fn; return {}; } });
let tour!: typeof captured, renders!: typeof captured, portfolio!: typeof captured;
try { await import("../tours/index.ts"); tour = captured; await import("../renders/index.ts"); renders = captured; await import("../portfolio/index.ts"); portfolio = captured; }
finally { Object.defineProperty(Deno, "serve", descriptor); }
const { handleCreative } = await import("../studio/creative.ts");
const { adminClient } = await import("./supabase.ts");
const response = (value: unknown) => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
type Options = { denyRender?: boolean; denyOptional?: boolean; revokeAfterFirst?: boolean; rpcFailure?: boolean; revokeAfterTwo?: boolean; missingVisibility?: boolean; invalidVisibility?: boolean; revokeDuringProfile?: boolean; clientContact?: boolean; changeContact?: boolean; denyContactPhoto?: boolean; mainPhotoKey?: string | null; coverPhoto?: Record<string,unknown> | null; revokeCoverAtFinal?: boolean; selection?:string[]|null; withHistoricalPhoto?:boolean; changeSelection?:boolean; identity?:Record<string,unknown>; changeIdentity?:boolean; identityFailure?:boolean; noDiscovery?:boolean; withdrawDiscovery?:boolean; clientFailure?:boolean; discovery?:unknown; emptyPortfolio?:boolean; withdrawPortfolio?:boolean; foreignPortfolioAgent?:boolean; removePortfolioMember?:boolean; deletingPortfolioActor?:boolean; legacyPortfolio?:boolean; expiredHosting?:boolean; hostingExpiresAfterAssembly?:boolean };
async function invoke(handler: "tour" | "renders" | "publish" | "creative" | "history" | "portfolio", opts: Options = {}) {
  const previous = globalThis.fetch; let checks = 0, profileRead = false, contactReads=0,listingReads=0,identityReads=0,hostingReads=0; const seen: Record<string, unknown>[] = [];
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "media-privacy-fixture.invalid");
    if (url.pathname === "/auth/v1/user") return response({ id: user, email: "fixture@example.invalid", is_anonymous: false });
    if (url.pathname === "/rest/v1/rpc/studio_presenter_media_visibility") {
      const args = await req.json(); seen.push(args); checks++;
      assertEquals(args.p_listing, listing);
      if (opts.rpcFailure) return new Response(JSON.stringify({ message: "permission backend unavailable" }), { status: 503, headers: { "content-type": "application/json" } });
      if (opts.missingVisibility) return response({ assets: {}, renders: {}, keys: {} });
      if (opts.invalidVisibility) return response({ assets: {}, renders: { [renderId]: "true" }, keys: {} });
      return response(Object.fromEntries(["assets", "renders", "keys"].map(kind => [kind, Object.fromEntries(args[`p_${kind}`].map((v: string) => [v,
        !(opts.revokeDuringProfile && profileRead) && !(opts.revokeAfterFirst && checks > 1) && !(opts.revokeAfterTwo && checks > 2) && !(opts.revokeCoverAtFinal && checks>=5 && [galleryId,galleryKey].includes(v)) && !(opts.denyRender && (v === renderId || v === asset || v === key)) && !(opts.denyOptional && [galleryId, galleryKey, altered].includes(v)) && !(opts.denyContactPhoto && [contactId,contactKey].includes(v))]))])));
    }
    if (url.pathname === "/rest/v1/rpc/publish_render") return response({ id: renderId, listing_id: listing, slug: "fixture-tour", video_key: key });
    if (url.pathname === "/rest/v1/rpc/public_listing_agent_identity") {
      const args=await req.json();assertEquals(args,{p_listing:listing});profileRead=true;identityReads++;
      if(opts.identityFailure)return new Response(JSON.stringify({message:"private SQL outage detail"}),{status:503,headers:{"content-type":"application/json"}});
      const identity=opts.identity??{personal_card:null,profile_name:"Fixture Agent",legacy_owned_single_member:false,org_business:{},org_handle:"fixture",legacy_brand:{},legacy_portrait:null};
      return response(opts.changeIdentity&&identityReads>1?{...identity,personal_card:null,profile_name:null}:identity);
    }
    if (url.pathname === "/rest/v1/rpc/assert_studio_edit_quality") return response(null);
    if (url.pathname === "/rest/v1/rpc/hosting_retention_state") { hostingReads++; return response(opts.expiredHosting || opts.hostingExpiresAfterAssembly && hostingReads >= (handler === "portfolio" ? 3 : 2) ? {org_id:org,policy:"prospective_90_day_grace",protected:false,retention_ends_at:"2020-01-01T00:00:00Z",hosting_available:false} : {org_id:org,policy:"preserved",protected:false,retention_ends_at:null,hosting_available:true}); }
    const table = url.pathname.split("/").pop();
    if (table === "renders") { const row = { id: renderId, job_id: jobId, listing_id: listing, slug: "fixture-tour", video_key: key, poster_key: `${prefix}/poster.jpg`, published_at: "2026-09-24T00:00:00Z", duration_s: 5 }; return response(handler === "portfolio" ? [row] : row); }
    if (table === "listings") {listingReads++; const row = { id: listing, org_id: org, agent_id: opts.foreignPortfolioAgent ? org : user, deleted_at: null, details: {allow_indexing: opts.noDiscovery || opts.withdrawDiscovery && profileRead ? false : "discovery" in opts ? opts.discovery : true}, address: "Synthetic listing",main_photo_key:opts.mainPhotoKey??null,gallery_asset_ids:opts.changeSelection&&listingReads>1?[]:opts.selection??null }; return response(handler === "portfolio" && !url.searchParams.get("id")?.startsWith("eq.") ? [row] : row); }
    if(table === "member_portfolios") return response({id:portfolioId,org_id:org,user_id:user,listing_ids:opts.emptyPortfolio || opts.withdrawPortfolio && profileRead ? []:[listing],revision:1});
    if(table === "memberships") return response(opts.removePortfolioMember && profileRead ? null : {user_id:user});
    if(table === "deletion_requests") return response(opts.deletingPortfolioActor ? [{id:portfolioId}] : []);
    if (table === "orgs") return response({ id: org, handle: "fixture", brand_kit: {} });
    if (table === "listing_client_contacts") {
      contactReads++;
      if(opts.clientFailure) return new Response(JSON.stringify({message:"private client lookup outage"}),{status:503,headers:{"content-type":"application/json"}});
      assert(!String(url.searchParams.get("select")).includes("recipient_email"), "private lead email must never be requested by public tour");
      return response(!opts.clientContact?null:{listing_id:listing,org_id:org,enabled:true,public_card:{name:"Client Realtor",title:"Listing Agent",email:"published@fixture.invalid"},hide_rendprop_branding:true,photo_asset_id:contactId,revision:opts.changeContact&&contactReads>1?2:1});
    }
    if (table === "profiles") { profileRead = true; return response({ name: "Fixture Agent" }); }
    if (table === "render_jobs") return response({ id: jobId, listing_id: listing, capture_asset_id: null, status: "completed" });
    if (table === "capture_assets") {
      if(url.searchParams.get("id")===`eq.${contactId}`)return response({id:contactId,listing_id:listing,kind:"photo",bucket:"renders",uploaded:true,storage_key:contactKey});
      if(url.searchParams.get("storage_key")?.startsWith("eq."))return response(opts.coverPhoto===undefined?{id:galleryId,listing_id:listing,kind:"photo",bucket:"renders",uploaded:true,storage_key:galleryKey}:opts.coverPhoto);
      return response([...(opts.withHistoricalPhoto?[{id:olderGalleryId,storage_key:olderGalleryKey}]:[]),{ id: galleryId, storage_key: galleryKey }]);
    }
    if (table === "media_provenance") return response([
      { kind: "video_reflection_removal", disclosure: "Edited video", original_key: key, altered_key: altered },
      ...(opts.withHistoricalPhoto?[
        {kind:"virtual_stage",disclosure:"Retired stage",original_key:`${prefix}/original-old.jpg`,altered_key:olderGalleryKey},
        {kind:"declutter",disclosure:"Current selected edit",original_key:`${prefix}/original-current.jpg`,altered_key:galleryKey},
      ]:[]),
    ]);
    if (table === "studio_creative_results") { const row = { id: resultId, listing_id: listing, org_id: org, user_id: user, kind: "video", bucket: "renders", storage_key: key,
      metadata: { state: "completed", video_kind: "edit", asset_id: asset, source_asset_ids: [asset] } }; return response(handler === "history" ? [row] : row); }
    throw new Error(`Unmodelled fixture request ${url.pathname}`);
  };
  try {
    const req = new Request(`https://app.fixture.invalid/${handler === "tour" ? "tours/fixture-tour" : handler === "renders" ? `renders/${jobId}` : handler === "publish" ? `renders/${jobId}/publish` : handler === "history" ? `studio/creative-results?listing_id=${listing}` : handler === "portfolio" ? opts.legacyPortfolio ? "portfolio/fixture" : `portfolio/member-${portfolioId}` : "studio/sign-media"}`, {
      method: ["creative", "publish"].includes(handler) ? "POST" : "GET", headers: { authorization: "Bearer synthetic-user" }, ...(["creative", "publish"].includes(handler) ? { body: JSON.stringify({ result_id: resultId }) } : {}),
    });
    const result = ["creative", "history"].includes(handler) ? await handleCreative(req, { userId: user, orgId: org, db: adminClient(), admin: adminClient(), authorizeListing: () => Promise.resolve() }) : await (handler === "tour" ? tour : handler === "portfolio" ? portfolio : renders)(req);
    assert(result); return { status: result.status, body: await result.json(), checks, seen };
  } finally { globalThis.fetch = previous; }
}
Deno.test("actual public tour service handler denies revoked published render lineage", async () => {
  const r = await invoke("tour", { denyRender: true }); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});
Deno.test("actual public tour filters revoked disclosure and gallery objects", async () => {
  const r = await invoke("tour", { denyOptional: true }); assertEquals(r.status, 200);
  assertEquals(r.body.gallery, []); assertEquals(r.body.altered_media, []); assert(r.body.video_url);
  assert(r.seen.some(call => (call.p_keys as string[]).includes(altered)));
});
Deno.test("actual public tour discards URLs on revocation during response assembly", async () => {
  const r = await invoke("tour", { revokeAfterFirst: true }); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});
Deno.test("actual native render status never emits fresh revoked tour links", async () => {
  for (const opts of [{ denyRender: true }, { revokeAfterFirst: true }]) {
    const r = await invoke("renders", opts); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("fixture-tour"));
  }
});
Deno.test("actual creative signed-link refresh suppresses revoked edit before and after signing", async () => {
  for (const opts of [{ denyRender: true }, { revokeAfterFirst: true }]) {
    const r = await invoke("creative", opts); assertEquals(r.status, 200); assertEquals(r.body.result.qc_publishable, false);
    assertEquals(r.body.result.url, undefined); assertEquals(r.body.result.source_url, undefined);
    assertEquals(r.checks, opts.denyRender ? 1 : 2);
  }
});
Deno.test("actual tour permission outages fail closed without media URLs", async () => {
  const r = await invoke("tour", { rpcFailure: true }); assertEquals(r.status, 503); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});

Deno.test("actual native publish replay rechecks privacy before returning object keys or share links", async () => {
  const r = await invoke("publish", { denyRender: true }); assertEquals(r.status, 404);
  assert(!JSON.stringify(r.body).includes("fixture-tour")); assert(!JSON.stringify(r.body).includes(key));
});

Deno.test("actual creative history rechecks the whole completed page before releasing any URL", async () => {
  const r = await invoke("history", { revokeAfterTwo: true }); assertEquals(r.status, 200); assertEquals(r.checks, 3);
  assertEquals(r.body.results[0].url, undefined); assertEquals(r.body.results[0].qc_publishable, false);
});

Deno.test("actual service portfolio omits revoked render posters and tour links", async () => {
  const r = await invoke("portfolio", { denyRender: true }); assertEquals(r.status, 200); assertEquals(r.body.tours, []);
  assert(!JSON.stringify(r.body).includes("fixture-tour")); assert(!JSON.stringify(r.body).includes("poster.jpg"));
});
Deno.test("actual service portfolio preserves permitted ordinary render cards", async () => {
  const r = await invoke("portfolio"); assertEquals(r.status, 200); assertEquals(r.checks, 2);
  assertEquals(r.body.tours[0].slug, "fixture-tour"); assertEquals(r.body.tours[0].poster, `https://media-fixture.invalid/${prefix}/poster.jpg`);
  assert(r.seen.every(call => (call.p_renders as string[]).includes(renderId)));
});
Deno.test("actual service portfolio rechecks permission after asynchronous profile read", async () => {
  const r = await invoke("portfolio", { revokeDuringProfile: true }); assertEquals(r.status, 200); assertEquals(r.checks, 2); assertEquals(r.body.tours, []);
});
Deno.test("actual service portfolio fails closed on unavailable or malformed visibility", async () => {
  for (const opts of [{ rpcFailure: true }, { missingVisibility: true }, { invalidVisibility: true }]) {
    const r = await invoke("portfolio", opts); assertEquals(r.status, 503); assert(!JSON.stringify(r.body).includes("fixture-tour"));
  }
});

Deno.test("actual public client tour shows only client identity and authoritative headshot", async () => {
  const r=await invoke("tour",{clientContact:true});assertEquals(r.status,200);
  assertEquals(r.body.agent_card,{name:"Client Realtor",title:"Listing Agent",email:"published@fixture.invalid",avatar_url:`https://media-fixture.invalid/${contactKey}`,handle:null});
  assertEquals(r.body.client_mode,true);assertEquals(r.body.hide_rendprop_branding,true);
  assert(!JSON.stringify(r.body).includes("Fixture Agent"));
  assert(!JSON.stringify(r.body.gallery).includes("contact-"));
  assert(r.seen.some(call=>(call.p_assets as string[]).includes(contactId)));
});
Deno.test("actual client tour discards mixed revisions and revoked headshot without photographer fallback",async()=>{
  const changed=await invoke("tour",{clientContact:true,changeContact:true});assertEquals(changed.status,503);
  assert(!JSON.stringify(changed.body).includes("Client Realtor"));
  const revoked=await invoke("tour",{clientContact:true,denyContactPhoto:true});assertEquals(revoked.status,200);
  assertEquals(revoked.body.agent_card.name,"Client Realtor");assertEquals(revoked.body.agent_card.avatar_url,undefined);
  assert(!JSON.stringify(revoked.body).includes(contactKey));
});
Deno.test("ordinary actual tour retains the agent mode when no client is assigned",async()=>{
 const r=await invoke("tour");assertEquals(r.status,200);assertEquals(r.body.agent_card.name,"Fixture Agent");
 assertEquals(r.body.client_mode,false);assertEquals(r.body.hide_rendprop_branding,false);
});
Deno.test("actual public team tour shows only assigned reviewed member plus scoped agency brand",async()=>{
 const identity={personal_card:{name:"Member Public",phone:"5552220002",email:"member-public@fixture.invalid"},profile_name:"Member Profile",legacy_owned_single_member:false,org_business:{brokerage:"Office",business_logo_url:`https://media-fixture.invalid/renders/${org}/brand/logo.png`},org_handle:"office",legacy_brand:{name:"Inviter",email:"inviter@fixture.invalid"},legacy_portrait:null};
 const r=await invoke("tour",{identity});assertEquals(r.status,200);assertEquals(r.body.agent_card,{name:"Member Public",handle:"office",phone:"5552220002",email:"member-public@fixture.invalid",brokerage:"Office",business_logo_url:`https://media-fixture.invalid/renders/${org}/brand/logo.png`});assert(!JSON.stringify(r.body).includes("inviter@"));
});
Deno.test("actual no-card and removed member tours never use inviter contact",async()=>{
 for(const profile_name of["Member Profile",null]){
  const r=await invoke("tour",{identity:{personal_card:null,profile_name,legacy_owned_single_member:false,org_business:{brokerage:"Office"},org_handle:"office",legacy_brand:{name:"Inviter",email:"inviter@fixture.invalid"},legacy_portrait:null}});
  assertEquals(r.status,200);assertEquals(r.body.agent_card,{name:profile_name,handle:"office",brokerage:"Office"});assert(!JSON.stringify(r.body).includes("inviter@"));
 }
});
Deno.test("actual public identity change or unavailable authority discards assembled contact and media",async()=>{
 for(const opts of[{changeIdentity:true},{identityFailure:true}]){const r=await invoke("tour",opts);assertEquals(r.status,503);assert(!JSON.stringify(r.body).includes("Fixture Agent"));assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));assert(!JSON.stringify(r.body).includes("private SQL"));}
});
Deno.test("actual explicit client delivery remains first without personal identity lookup",async()=>{
 const r=await invoke("tour",{clientContact:true,identityFailure:true});assertEquals(r.status,200);assertEquals(r.body.agent_card.name,"Client Realtor");
});
Deno.test("actual public legacy portrait needs exact configured origin and final asset visibility",async()=>{
 const base={personal_card:{name:"Owner Public"},profile_name:"Owner Profile",legacy_owned_single_member:false,org_business:{},org_handle:"owner",legacy_brand:{},legacy_portrait:{asset_id:galleryId,storage_key:galleryKey,url:`https://media-fixture.invalid/${galleryKey}`}};
 const good=await invoke("tour",{identity:base});assertEquals(good.status,200);assertEquals(good.body.agent_card.avatar_url,`https://media-fixture.invalid/${galleryKey}`);assert((good.seen.at(-1)!.p_assets as string[]).includes(galleryId));
 const foreign=await invoke("tour",{identity:{...base,legacy_portrait:{...base.legacy_portrait,url:`https://foreign.fixture.invalid/${galleryKey}`}}});assertEquals(foreign.status,200);assertEquals(foreign.body.agent_card.avatar_url,undefined);
 const revoked=await invoke("tour",{identity:base,denyOptional:true});assertEquals(revoked.status,404);assert(!JSON.stringify(revoked.body).includes("Owner Public"));
});
Deno.test("actual public cover resolves the saved gallery selection and joins final visibility fencing",async()=>{
  const r=await invoke("tour",{mainPhotoKey:galleryKey});assertEquals(r.status,200);assertEquals(r.body.cover_url,`https://media-fixture.invalid/${galleryKey}`);
  const last=r.seen.at(-1)!;assert((last.p_assets as string[]).includes(galleryId));assert((last.p_keys as string[]).includes(galleryKey));
  const revoked=await invoke("tour",{mainPhotoKey:galleryKey,revokeCoverAtFinal:true});assertEquals(revoked.status,404);assert(!JSON.stringify(revoked.body).includes("media-fixture.invalid"));
});
Deno.test("actual public cover omits invalid, unuploaded, cross-scope and revoked references",async()=>{
  for(const mainPhotoKey of [null,contactKey,key,`https://fixture.invalid/${galleryKey}`,galleryKey.replace(listing,asset),galleryKey+"?x=1"]){
    const r=await invoke("tour",{mainPhotoKey});assertEquals(r.status,200);assertEquals(r.body.cover_url,null);
  }
  const base={id:galleryId,listing_id:listing,kind:"photo",bucket:"renders",uploaded:true,storage_key:galleryKey};
  for(const coverPhoto of [null,{...base,listing_id:asset},{...base,storage_key:galleryKey.replace(org,user)},{...base,uploaded:false},{...base,kind:"video"},{...base,storage_key:contactKey}]){
    const r=await invoke("tour",{mainPhotoKey:galleryKey,coverPhoto});assertEquals(r.status,200);assertEquals(r.body.cover_url,null);
  }
  const denied=await invoke("tour",{mainPhotoKey:galleryKey,denyOptional:true});assertEquals(denied.status,200);assertEquals(denied.body.cover_url,null);
});
Deno.test("actual tour explicit current gallery excludes historical staged uploads and preserves selected order",async()=>{
  const current=await invoke("tour",{selection:[galleryId],withHistoricalPhoto:true,mainPhotoKey:galleryKey});assertEquals(current.status,200);
  assertEquals(current.body.gallery,[{url:`https://media-fixture.invalid/${galleryKey}`}]);assertEquals(current.body.cover_url,`https://media-fixture.invalid/${galleryKey}`);
  assert(!JSON.stringify(current.body.gallery).includes("old-staged"));
  assert(!JSON.stringify(current.body.altered_media).includes("old-staged"));
  assertEquals(current.body.altered_media.map((r:{kind:string})=>r.kind),["video_reflection_removal","declutter"]);
  assert(current.body.altered_media[1].disclosure.includes("Compare with the original"));
  const ordered=await invoke("tour",{selection:[galleryId,olderGalleryId],withHistoricalPhoto:true});assertEquals(ordered.body.gallery,[{url:`https://media-fixture.invalid/${galleryKey}`},{url:`https://media-fixture.invalid/${olderGalleryKey}`}]);
  const legacy=await invoke("tour",{withHistoricalPhoto:true});assertEquals(legacy.body.gallery.length,2);
});
Deno.test("actual tour empty gallery selection hides property photos and saved cover without changing video",async()=>{
  const r=await invoke("tour",{selection:[],withHistoricalPhoto:true,mainPhotoKey:galleryKey});assertEquals(r.status,200);
  assertEquals(r.body.gallery,[]);assertEquals(r.body.cover_url,null);assert(r.body.video_url);
  assertEquals(r.body.altered_media.map((r:{kind:string})=>r.kind),["video_reflection_removal"]);
  const excludedCover=await invoke("tour",{selection:[olderGalleryId],mainPhotoKey:galleryKey,withHistoricalPhoto:true});assertEquals(excludedCover.body.cover_url,null);
});
Deno.test("actual tour discards a retired version if gallery selection changes during assembly",async()=>{
 const r=await invoke("tour",{selection:[galleryId],mainPhotoKey:galleryKey,changeSelection:true});assertEquals(r.status,503);
 assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});

Deno.test("actual portfolio excludes private-link-only and client-delivery listings",async()=>{
 for(const opts of[{noDiscovery:true},{clientContact:true}]){const r=await invoke("portfolio",opts);assertEquals(r.status,200);assertEquals(r.body.tours,[]);assertEquals(r.checks,0);}
});
Deno.test("actual portfolio rechecks withdrawn discovery and fails closed on client lookup outage",async()=>{
 const withdrawn=await invoke("portfolio",{withdrawDiscovery:true});assertEquals(withdrawn.status,200);assertEquals(withdrawn.body.tours,[]);assertEquals(withdrawn.checks,1);
 const outage=await invoke("portfolio",{clientFailure:true});assertEquals(outage.status,503);assert(!JSON.stringify(outage.body).includes("fixture-tour"));assert(!JSON.stringify(outage.body).includes("private client lookup outage"));
});

Deno.test("actual portfolio preserves native string opt-in but refuses truthy non-consent",async()=>{
 const native=await invoke("portfolio",{discovery:"true"});assertEquals(native.status,200);assertEquals(native.body.tours.length,1);
 for(const discovery of["false","anything",{},null]){const denied=await invoke("portfolio",{discovery});assertEquals(denied.status,200);assertEquals(denied.body.tours,[]);}
});

Deno.test("actual member portfolio requires explicit selection and the current listing agent",async()=>{
 for(const opts of [{emptyPortfolio:true},{foreignPortfolioAgent:true},{withdrawPortfolio:true}]){
  const result=await invoke("portfolio",opts);assertEquals(result.status,200);assertEquals(result.body.tours,[]);
 }
 const legacy=await invoke("portfolio",{legacyPortfolio:true});assertEquals(legacy.status,200);assertEquals(legacy.body.tours,[]);assertEquals(legacy.body.agent_card.name,null);
});
Deno.test("actual member portfolio refuses removed or deleting actors after assembly",async()=>{
 for(const opts of [{removePortfolioMember:true},{deletingPortfolioActor:true}]){const result=await invoke("portfolio",opts);assertEquals(result.status,404);assert(!JSON.stringify(result.body).includes("fixture-tour"));}
});

Deno.test("actual public tour and member portfolio deny expired hosting and final deadline withdrawal",async()=>{
 for(const route of["tour","portfolio"]as const)for(const opts of[{expiredHosting:true},{hostingExpiresAfterAssembly:true}])assertEquals((await invoke(route,opts)).status,404);
});
