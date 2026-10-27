// Actual deployed handler, with only PostgREST/Auth transport doubled. No
// credential-bearing object URL, customer record or storage request is used.
import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",render="30000000-0000-4000-8000-000000000003",job="40000000-0000-4000-8000-000000000004",photo="50000000-0000-4000-8000-000000000005",other="60000000-0000-4000-8000-000000000006",slug="fixture-delivery",base=`renders/${org}/${listing}`,video=`${base}/finished.mp4`,poster=`${base}/poster.jpg`,gallery=`${base}/gallery-selected.jpg`,retired=`${base}/gallery-retired.jpg`;
for(const[name,value]of Object.entries({SUPABASE_URL:"https://media-delivery-fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture",CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"fixture",R2_SECRET_ACCESS_KEY:"fixture-secret",R2_PUBLIC_BASE_URL:"https://media.fixture.invalid",PUBLIC_MEDIA_DELIVERY:"proxy-v1",MEDIA_GATEWAY_SECRET:"d".repeat(64)}))Deno.env.set(name,value);
let handler!:(req:Request)=>Promise<Response>;const descriptor=Object.getOwnPropertyDescriptor(Deno,"serve")!;
Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:typeof handler)=>{handler=fn;return {};}});
try{await import("./index.ts");}finally{Object.defineProperty(Deno,"serve",descriptor);}
async function invoke(options:{unpublish?:boolean;changedObject?:boolean;revokedAtFinal?:boolean;missingPermission?:boolean;crossProperty?:boolean;deleteAtFinal?:boolean;withStream?:boolean;expiredHosting?:boolean;hostingExpiresAtFinal?:boolean;badHostingReceipt?:boolean;photoVideo?:boolean;compositionChanged?:boolean;publicPage?:boolean;selectedCover?:boolean;photoSelectionChanged?:boolean;contactChanged?:boolean;identityChanged?:boolean;revokedAtPublicFinal?:boolean;parallelInitialBarrier?:boolean;parallelFinalBarrier?:boolean;parallelOptionalBarrier?:boolean;contactPortraitRevoked?:boolean;preview?:boolean;previewDisclosure?:boolean;previewLegacy?:boolean;duplicatePreviewKey?:boolean;missingGateway?:boolean}={}){
 const original=globalThis.fetch;let renders=0,listings=0,permissions=0,retentionReads=0;const requests:string[]=[];let presentationReads=0,contacts=0,identities=0,contactChecks=0,photoReads=0,coverReads=0;const contactKey=`${base}/contact-fixture.jpg`;
 const finalReads=new Set<string>();let releaseFinal!:()=>void;const finalGate=new Promise<void>(resolve=>{releaseFinal=resolve;});
 const finalRead=async(kind:string)=>{if(!options.parallelFinalBarrier)return;finalReads.add(kind);if(finalReads.size===3)releaseFinal();let timer:ReturnType<typeof setTimeout>|undefined;try{await Promise.race([finalGate,new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(Error("Final independent reads were serialized or omitted")),2000);})]);}finally{if(timer!==undefined)clearTimeout(timer);}};
 const optionalReads=new Set<string>();let releaseOptional!:()=>void;const optionalGate=new Promise<void>(resolve=>{releaseOptional=resolve;});
 const optionalRead=async(kind:string)=>{if(!options.parallelOptionalBarrier)return;optionalReads.add(kind);if(optionalReads.size===3)releaseOptional();let timer:ReturnType<typeof setTimeout>|undefined;try{await Promise.race([optionalGate,new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(Error("Optional independent reads were serialized or omitted")),2000);})]);}finally{if(timer!==undefined)clearTimeout(timer);}};
 const initialReads=new Set<string>();let releaseInitial!:()=>void;const initialGate=new Promise<void>(resolve=>{releaseInitial=resolve;});
 const initialRead=async(kind:string)=>{if(!options.parallelInitialBarrier)return;initialReads.add(kind);if(initialReads.size===2)releaseInitial();let timer:ReturnType<typeof setTimeout>|undefined;try{await Promise.race([initialGate,new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(Error("Gallery and presentation reads were serialized")),2000);})]);}finally{if(timer!==undefined)clearTimeout(timer);}};
 const reply=(data:unknown,status=200)=>Response.json(data,{status});
 globalThis.fetch=async(raw,init)=>{
  const req=new Request(raw,init),u=new URL(req.url);assertEquals(u.hostname,"media-delivery-fixture.invalid");requests.push(u.pathname);
  if(u.pathname.endsWith("/rpc/published_photo_delivery")){
   photoReads++;assertEquals(await req.json(),{p_slug:slug,p_key:gallery,p_bytes:0});
   if(options.unpublish||options.photoSelectionChanged||options.expiredHosting)return reply({code:"P0001",message:"RP404: current published photo refused"},400);
   if(options.missingPermission)return reply({code:"P0001",message:"RP503: incomplete canonical visibility"},400);
   return reply(options.previewLegacy?null:{schema:1,slug,objects:{[gallery]:"renders"},stream_uid:null});
  }
  if(u.pathname.endsWith("/rpc/property_public_presentation")){presentationReads++;if(presentationReads===1)await initialRead("presentation");return reply(options.photoVideo?{website_theme:"basic",listing_video:{composition_id:render,asset_id:photo,poster_asset_id:other,storage_key:`${base}/${options.compositionChanged&&presentationReads>1?"new-selected":"selected"}.mp4`,poster_key:`${base}/first-clip.jpg`,width:1920,height:1080,duration_s:15,branding_policy:"unbranded",disclosure:"Photo movement",source_asset_ids:[photo]}}:null);}
  if(u.pathname.endsWith("/rpc/media_delivery_admit")){const body=await req.json();assertEquals(body,{p_org:org,p_bytes:0,p_required:true});return reply({admitted:true,legacy_unbudgeted:false});}
  if(u.pathname.endsWith("/rpc/studio_presenter_media_visibility")){
   permissions++;const p=await req.json();assertEquals(p.p_listing,listing);if(p.p_keys.includes(contactKey))contactChecks++;
   if(options.missingPermission)return reply({assets:{},renders:{},keys:{}});
   return reply(Object.fromEntries(["assets","renders","keys"].map(kind=>[kind,Object.fromEntries(p[`p_${kind}`].map((key:string)=>[key,!(options.revokedAtFinal&&permissions>=4 || options.revokedAtPublicFinal&&permissions>=3 || options.contactPortraitRevoked&&key===contactKey&&contactChecks>=3)]))])));
  }
  if(u.pathname.endsWith("/rpc/public_listing_agent_identity")){identities++;if(identities>1)await finalRead("identity");return reply({personal_card:null,profile_name:options.identityChanged&&identities>1?"Changed Agent":"Synthetic Agent",legacy_owned_single_member:false,org_business:{},org_handle:"fixture",legacy_brand:{},legacy_portrait:null});}
  if(u.pathname.endsWith("/rpc/hosting_retention_state")){retentionReads++;return reply(options.badHostingReceipt?{org_id:other}:options.expiredHosting||options.hostingExpiresAtFinal&&retentionReads>1?{org_id:org,policy:"prospective_90_day_grace",protected:false,retention_ends_at:"2020-01-01T00:00:00Z",hosting_available:false}:{org_id:org,policy:"preserved",protected:false,retention_ends_at:null,hosting_available:true});}
  const table=u.pathname.split("/").at(-1);
  if(table==="renders"){
   renders++;if(options.unpublish&&renders>1)return reply(null);
   return reply({id:render,listing_id:listing,job_id:job,slug,presentation_kind:options.photoVideo?"photo_video":"recorded_walkthrough",video_key:options.changedObject&&renders>1?video+"changed":video,poster_key:poster,stream_uid:options.withStream?"f".repeat(32):null,published_at:"2026-10-06T00:00:00Z"});
  }
  if(table==="listings"){listings++;if(listings>1)await finalRead("photos");return reply({id:listing,org_id:org,agent_id:other,deleted_at:options.deleteAtFinal&&listings>1?"2026-10-06":null,details:{gallery:[{url:`https://media.fixture.invalid/${retired}`}],floor_measurements_v1:"private-sentinel"},main_photo_key:options.selectedCover?gallery:null,gallery_asset_ids:options.photoSelectionChanged&&listings>1?[other]:[photo]});}
  if(table==="render_jobs")return reply({capture_asset_id:options.parallelOptionalBarrier?other:null});
  if(table==="capture_chapters"){await optionalRead("chapters");return reply([]);}
  if(table==="listing_client_contacts"){contacts++;if(contacts>1)await finalRead("contact");if(options.parallelOptionalBarrier)return reply({listing_id:listing,org_id:org,enabled:true,revision:1,photo_asset_id:other,public_card:{name:"Synthetic Client"}});return reply(options.contactChanged&&contacts>1?{listing_id:listing,org_id:org,enabled:true,revision:2}:null);}
  if(table==="media_provenance"){await optionalRead("disclosures");return reply(options.previewDisclosure?[{id:other,kind:"photo",edit:"declutter",label:"Fixture",disclosure:"Digitally decluttered",original_key:`${base}/original.jpg`,altered_key:gallery,created_at:"2026-10-06T00:00:00Z"}]:[]);}
  if(table==="capture_assets"&&u.searchParams.get("storage_key")===`eq.${gallery}`){coverReads++;return reply({id:photo,listing_id:listing,kind:"photo",bucket:"renders",storage_key:gallery,uploaded:true,upload_aborted:false,bytes:10000,content_type:"image/jpeg",created_at:"2026-10-06T00:00:00Z"});}
  if(table==="capture_assets"&&u.searchParams.get("id")===`eq.${other}`){await optionalRead("portrait");return reply({id:other,listing_id:listing,kind:"photo",bucket:"renders",storage_key:contactKey,uploaded:true});}
  if(table==="capture_assets"){await initialRead("gallery");return reply([{id:photo,storage_key:options.crossProperty?gallery.replace(listing,other):gallery},{id:other,storage_key:retired}]);}
  throw Error("Unexpected fixture request "+u.pathname);
 };
 const route=options.preview?`/photo-delivery?key=${encodeURIComponent(gallery)}${options.duplicatePreviewKey?`&key=${encodeURIComponent(retired)}`:""}`:options.publicPage?"":"/delivery";
 try{const res=await handler(new Request(`https://api.fixture.invalid/tours/${slug}${route}`,{headers:options.missingGateway?{}:{"X-Rendprop-Media-Gateway":"d".repeat(64)}}));return{status:res.status,body:await res.json(),timing:res.headers.get("Server-Timing"),renders,listings,permissions,requests,contacts,identities,initialReads:[...initialReads],finalReads:[...finalReads],optionalReads:[...optionalReads],contactChecks,photoReads,coverReads};}finally{globalThis.fetch=original;}
}
Deno.test("actual thumbnail authority route admits one photo without building contacts or unrelated media",async()=>{
 const r=await invoke({preview:true});assertEquals(r.status,200);assertEquals(r.body,{schema:1,slug,objects:{[gallery]:"renders"},stream_uid:null});assertEquals(r.contacts,0);assertEquals(r.identities,0);assertEquals(r.renders,0);assertEquals(r.listings,0);assertEquals(r.photoReads,1);assertEquals(r.requests,["/rest/v1/rpc/published_photo_delivery"]);
});
Deno.test("thumbnail route keeps gateway, exact-key checks and current authority refusals",async()=>{
 for(const options of[{missingGateway:true},{duplicatePreviewKey:true},{unpublish:true},{photoSelectionChanged:true},{expiredHosting:true},{missingPermission:true}]){const r=await invoke({preview:true,...options});assert([400,403,404,503].includes(r.status));assert(!JSON.stringify(r.body).includes(gallery));assertEquals(r.contacts,0);assertEquals(r.renders,0);assertEquals(r.photoReads,options.missingGateway||options.duplicatePreviewKey?0:1);}
});
Deno.test("known saved edits use the same one-object route without assembling unrelated disclosures or contacts",async()=>{
 const r=await invoke({preview:true,previewDisclosure:true});assertEquals(r.status,200);assertEquals(r.body,{schema:1,slug,objects:{[gallery]:"renders"},stream_uid:null});assertEquals(r.photoReads,1);assertEquals(r.requests,["/rest/v1/rpc/published_photo_delivery"]);
});
Deno.test("unsupported legacy lineage alone falls through the existing complete delivery authority",async()=>{
 const r=await invoke({preview:true,previewDisclosure:true,previewLegacy:true});assertEquals(r.status,200);assertEquals(r.body.objects[gallery],"renders");assertEquals(r.body.objects[video],"renders");assert(r.contacts>0);
});
Deno.test("actual delivery endpoint carries only DB-published video/poster/current selected gallery exact identities",async()=>{
 const r=await invoke();assertEquals(r.status,200);assertEquals(r.body,{schema:1,slug,objects:{[gallery]:"renders",[video]:"renders",[poster]:"renders"},stream_uid:null});assertEquals(r.renders,2);assert(r.permissions>=4);assert(!JSON.stringify(r.body).includes(retired));assert(!JSON.stringify(r.body).includes("private-sentinel"));
});
Deno.test("actual delivery endpoint rereads publication and immutable object references at the byte-capability boundary",async()=>{
 for(const options of [{unpublish:true},{changedObject:true}]){const r=await invoke(options);assertEquals(r.status,404);assert(!JSON.stringify(r.body).includes(video));}
});
Deno.test("actual delivery endpoint fails closed for revoked approval, incomplete authority, deleted listing and cross-property key substitution",async()=>{
 for(const options of [{revokedAtFinal:true},{missingPermission:true},{deleteAtFinal:true}]){const r=await invoke(options);assert([404,503].includes(r.status));assert(!JSON.stringify(r.body).includes(video));}
 const cross=await invoke({crossProperty:true});assertEquals(cross.status,200);assertEquals(cross.body.objects,{[video]:"renders",[poster]:"renders"});
});
Deno.test("future protected Stream UID is exact published render identity while unverified HLS delivery stays disabled",async()=>{
 const r=await invoke({withStream:true});assertEquals(r.status,200);assertEquals(r.body.stream_uid,"f".repeat(32));
 const {publishedStreamUrl,publishedR2Url}=await import("../_shared/r2.ts");Deno.env.delete("STREAM_PRIVATE_PLAYBACK");assertEquals(publishedStreamUrl(slug,"f".repeat(32)),null);assertEquals(publishedR2Url(slug,video),`https://rendprop.com/media/${slug}/r2/${encodeURIComponent(video)}`);
});

Deno.test("actual byte admission refuses expired hosting and deadline withdrawal after assembly",async()=>{
 for(const options of[{expiredHosting:true},{hostingExpiresAtFinal:true}])assertEquals((await invoke(options)).status,404);
 assertEquals((await invoke({badHostingReceipt:true})).status,503);
});

Deno.test("photo-only anchor delivers selected composition and independent poster without stale anchor/recorded media",async()=>{
 const r=await invoke({photoVideo:true});assertEquals(r.status,200);assertEquals(r.body.objects,{[gallery]:"renders",[`${base}/selected.mp4`]:"renders",[`${base}/first-clip.jpg`]:"renders"});assert(!Object.hasOwn(r.body.objects,video));assert(!Object.hasOwn(r.body.objects,poster));
});
Deno.test("composition reselection during byte authority is refused rather than exposing the previous video",async()=>{
 const r=await invoke({photoVideo:true,compositionChanged:true});assertEquals(r.status,503);assert(!JSON.stringify(r.body).includes("selected.mp4"));
});

Deno.test("actual public tour overlaps final independent snapshots and shares one initial contact query",async()=>{
 const r=await invoke({publicPage:true,parallelFinalBarrier:true});assertEquals(r.status,200);assertEquals(r.listings,2);assertEquals(r.contacts,2);assertEquals(r.identities,2);assertEquals(new Set(r.finalReads),new Set(["photos","contact","identity"]));assert(!JSON.stringify(r.body).includes("private-sentinel"));
 assert(r.timing);const phases=r.timing.split(", ");assertEquals(phases.map(p=>p.split(";")[0]),["context","gallery_contact_presentation","disclosures_chapters_contact","optional_media","fresh_metadata","media_fence","total"]);for(const phase of phases)assert(/^[a-z_]+;dur=\d+\.\d$/.test(phase));assert(!r.timing.includes(listing));assert(!r.timing.includes(org));
});
Deno.test("selected cover reuses the same verified gallery identity without a second physical-publication walk",async()=>{
 const r=await invoke({publicPage:true,selectedCover:true});assertEquals(r.status,200);
 assertEquals(r.body.cover_url,`https://rendprop.com/media/${slug}/r2/${encodeURIComponent(gallery)}`);
 assertEquals(r.coverReads,0);
});
Deno.test("the property presentation and selected gallery begin together before final authority fences",async()=>{
 const r=await invoke({publicPage:true,parallelInitialBarrier:true});assertEquals(r.status,200);
 assertEquals(new Set(r.initialReads),new Set(["gallery","presentation"]));
 assertEquals(r.listings,2);assertEquals(r.contacts,2);
});
Deno.test("parallel public assembly retains fresh photo, contact, identity, media, presentation and hosting refusals",async()=>{
 for(const fault of [{photoSelectionChanged:true},{contactChanged:true},{identityChanged:true},{revokedAtPublicFinal:true},{photoVideo:true,compositionChanged:true},{hostingExpiresAtFinal:true},{deleteAtFinal:true}]){const r=await invoke({publicPage:true,...fault});assert([403,404,503].includes(r.status),JSON.stringify(fault));assert(!JSON.stringify(r.body).includes(gallery));assert(!JSON.stringify(r.body).includes("private-sentinel"));}
});

Deno.test("actual public page overlaps disclosures, chapters and contact portrait while preserving its fresh lineage fence",async()=>{
 const r=await invoke({publicPage:true,parallelOptionalBarrier:true});assertEquals(r.status,200);assertEquals(new Set(r.optionalReads),new Set(["disclosures","chapters","portrait"]));assertEquals(r.contacts,2);assertEquals(r.identities,0);assert(r.contactChecks>=3);assert(typeof r.body.agent_card.avatar_url==="string");
 const revoked=await invoke({publicPage:true,parallelOptionalBarrier:true,contactPortraitRevoked:true});assertEquals(revoked.status,404);assert(!JSON.stringify(revoked.body).includes("contact-fixture"));
});
