// Exercise the deployed listing handler against a closed synthetic transport.
// No customer, object storage, provider or network socket is used.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const ORG="a0200205-0000-4000-8000-000000000001", LISTING="a0200205-0000-4000-8000-000000000002";
const USER="a0200205-0000-4000-8000-000000000003", ASSET="a0200205-0000-4000-8000-000000000004";
const OTHER="a0200205-0000-4000-8000-000000000005", KEY=`renders/${ORG}/${LISTING}/gallery-${ASSET}.jpg`;
for (const [k,v] of Object.entries({SUPABASE_URL:"https://main-photo-fixture.invalid",SUPABASE_ANON_KEY:"fixture-anon",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",CLOUDFLARE_ACCOUNT_ID:"fixture",R2_ACCESS_KEY_ID:"fixture",R2_SECRET_ACCESS_KEY:"fixture",R2_PUBLIC_BASE_URL:"https://cover.fixture.invalid"})) Deno.env.set(k,v);
type Handler=(req:Request)=>Promise<Response>;
let handler!:Handler;
const serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
try {
  Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return {};}});
  await import("./index.ts");
} finally {Object.defineProperty(Deno,"serve",serve);}
type Options={photo?:Record<string,unknown>|null; visible?:boolean; visibilityFailure?:boolean; listingMissing?:boolean; readOnly?:boolean; deleting?:boolean; workspace?:string; selection?:string[]|null; existingKey?:string|null; appendFailure?:boolean;removeError?:{code?:string;message?:string};removeAck?:Record<string,unknown>;removeReplayed?:boolean;idempotencyKey?:string|null};
async function invoke(body:Record<string,unknown>,options:Options={},method="PATCH") {
  const previous=globalThis.fetch, updates:Record<string,unknown>[]=[],appends:Record<string,unknown>[]=[],removals:Record<string,unknown>[]=[],snapshots:Record<string,unknown>[]=[];
  let visibilityReads=0,assetReads=0;
  const row={id:LISTING,org_id:ORG,main_photo_key:options.existingKey===undefined?KEY:options.existingKey,gallery_asset_ids:options.selection??null,address:"Original"};
  const photo=options.photo===undefined?{id:ASSET,listing_id:LISTING,kind:"photo",bucket:"renders",uploaded:true,storage_key:KEY}:options.photo;
  const response=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{"content-type":"application/json"}});
  globalThis.fetch=async(input,init)=>{
    const req=new Request(input,init),url=new URL(req.url);assertEquals(url.hostname,"main-photo-fixture.invalid");
    if(url.pathname==="/auth/v1/user")return response({id:USER,is_anonymous:false});
    if(url.pathname.endsWith("workspace_directory"))return response({actor_id:USER,own_org_id:ORG,billing_org_id:ORG,can_switch_agent_libraries:true,active_org_id:options.workspace??ORG,workspaces:[ORG,OTHER].map(id=>({id,name:"Fixture",role:options.readOnly?"marketing":"owner",access_mode:"own",library_owner_user_id:USER,billing_org_id:id,can_read:true,can_write:!options.readOnly,can_manage_subscription:!options.readOnly}))});
    if(url.pathname.endsWith("listing_library_scope")){
      const args=await req.json();assertEquals(args,{p_actor:USER,p_listing:LISTING});
      return response({actor_id:USER,listing_id:LISTING,org_id:ORG,library_org_id:ORG,library_owner_user_id:USER,listing_owner_user_id:USER,role:options.readOnly?"marketing":"owner",access_mode:"own",can_read:!options.listingMissing,can_write:!options.listingMissing&&!options.readOnly,can_manage_subscription:!options.readOnly,billing_org_id:ORG,team_org_id:null});
    }
    if(url.pathname.endsWith("active_org_for_user"))return response(ORG);
    if(url.pathname.endsWith("deletion_requests"))return response(options.deleting?[{id:OTHER}]:[]);
    if(url.pathname.endsWith("studio_presenter_media_visibility")){
      visibilityReads++;const args=await req.json();assertEquals(args.p_listing,LISTING);
      if(options.visibilityFailure)return response({message:"Synthetic outage"},503);
      return response(Object.fromEntries(["assets","renders","keys"].map(k=>[k,Object.fromEntries(args[`p_${k}`].map((v:string)=>[v,options.visible!==false]))])));
    }
    if(url.pathname.endsWith("append_listing_gallery")){
      const args=await req.json();appends.push(args);assertEquals(args.p_user,USER);assertEquals(args.p_org,ORG);assertEquals(args.p_listing,LISTING);
      if(options.readOnly)return response({message:"RP403: your role does not permit editing client delivery"},400);
      if(options.appendFailure)return response({message:"Synthetic append outage"},503);
      const existing=options.selection??[];
      const saved={...row,gallery_asset_ids:[...new Set([...existing,...args.p_add])],main_photo_key:args.p_set_main?args.p_main_photo_key:row.main_photo_key};
      return response(saved);
    }
    if(url.pathname.endsWith("listing_gallery_snapshot")){
      const args=await req.json();snapshots.push(args);assertEquals(args,{p_user:USER,p_org:ORG,p_listing:LISTING});
      return response({...row,gallery_assets:options.visible===false?[]:[{asset_id:ASSET,sha256:"a".repeat(64),bytes:1024}]});
    }
    if(url.pathname.endsWith("remove_listing_gallery")){
      const args=await req.json();removals.push(args);assertEquals(args.p_user,USER);assertEquals(args.p_org,ORG);assertEquals(args.p_listing,LISTING);
      if(options.removeError)return response(options.removeError,400);
      const selected=options.selection??[ASSET];
      const removed=selected.filter((id:string)=>args.p_remove.includes(id));
      return response({...row,gallery_asset_ids:options.removeReplayed?selected:selected.filter((id:string)=>!args.p_remove.includes(id)),
        main_photo_key:options.removeReplayed?row.main_photo_key:removed.includes(ASSET)?null:row.main_photo_key,
        gallery_remove:{actor_id:USER,operation_id:args.p_operation,replayed:options.removeReplayed??false,requested_asset_ids:args.p_remove,removed_asset_ids:removed,...options.removeAck}});
    }
    if(url.pathname.endsWith("capture_assets")){
      assetReads++;assertEquals(url.searchParams.get("listing_id"),`eq.${LISTING}`);
      assert(url.searchParams.has("id")||url.searchParams.has("storage_key"));return response(photo);
    }
    if(url.pathname.endsWith("listings")){
      if(req.method==="PATCH") {const patch=await req.json();updates.push(patch);if(options.readOnly)return response(null);Object.assign(row,patch);}
      return response(options.listingMissing?null:row);
    }
    throw new Error(`Unmodeled synthetic request ${url.pathname}`);
  };
  try {
    const key=options.idempotencyKey===undefined&&typeof body.gallery_remove_operation_id==="string"?`gallery-remove:${body.gallery_remove_operation_id}`:options.idempotencyKey;
    const r=await handler(new Request(`https://edge.fixture.invalid/listings${method==="POST"?"":`/${LISTING}`}${method==="GET"?"?gallery_selection=1":""}`,{
      method,headers:{authorization:"Bearer fixture",...(options.workspace?{"x-org-id":options.workspace}:{}),...(key?{"Idempotency-Key":key}:{})},body:method==="GET"?undefined:JSON.stringify(body),
    }));
    return {status:r.status,body:await r.json(),updates,assetReads,visibilityReads,appends,removals,snapshots};
  }finally{globalThis.fetch=previous;}
}
Deno.test("actual cover PATCH resolves an uploaded property photo to its canonical key",async()=>{
  for(const body of [{main_photo_asset_id:ASSET},{main_photo_asset_id:ASSET.toUpperCase()},{main_photo_key:KEY}]){
    const r=await invoke(body);assertEquals(r.status,200);assertEquals(r.updates,[{main_photo_key:KEY}]);assertEquals(r.visibilityReads,1);
    assertEquals(r.body.main_photo_asset_id,undefined);
  }
});
Deno.test("legacy ordinary PATCH is fenced and explicit cover null still clears it",async()=>{
  const omitted=await invoke({address:"Changed"});assertEquals(omitted.status,426);
  assertEquals(omitted.updates,[]);assertEquals(omitted.assetReads,0);
  for(const field of ["main_photo_asset_id","main_photo_key"]){const r=await invoke({[field]:null});assertEquals(r.status,200);assertEquals(r.body.main_photo_key,null);assertEquals(r.assetReads,0);}
});
Deno.test("actual cover PATCH rejects URLs, malformed IDs, both selectors and forged paths without updating",async()=>{
  for(const body of [{main_photo_asset_id:"bad"},{main_photo_asset_id:ASSET,main_photo_key:null},{main_photo_key:`https://fixture.invalid/${KEY}`},{main_photo_key:KEY.replace(ORG,OTHER)},{main_photo_key:KEY.replace(LISTING,OTHER)},{main_photo_key:KEY.replace("gallery-","contact-")},{main_photo_key:KEY.replace("gallery-","gallery-../")},{main_photo_key:KEY+"?x=1"},{main_photo_key:42}]){
    const r=await invoke(body);assertEquals(r.status,400);assertEquals(r.updates,[]);
  }
});
Deno.test("actual cover PATCH refuses wrong listing, org prefix, role, upload and missing asset rows",async()=>{
  const base={id:ASSET,listing_id:LISTING,kind:"photo",bucket:"renders",uploaded:true,storage_key:KEY};
  for(const photo of [null,{...base,listing_id:OTHER},{...base,id:OTHER},{...base,storage_key:KEY.replace(ORG,OTHER)},{...base,storage_key:KEY.replace(LISTING,OTHER)},{...base,kind:"video"},{...base,bucket:"uploads"},{...base,uploaded:false},{...base,storage_key:KEY.replace("gallery-","contact-")},{...base,storage_key:KEY.replace("gallery-","poster-")}]){
    const r=await invoke({main_photo_asset_id:ASSET},{photo});assertEquals(r.status,400);assertEquals(r.updates,[]);
  }
});
Deno.test("actual cover PATCH obeys visibility, workspace, deletion and write authority",async()=>{
  for(const [options,status] of [[{visible:false},400],[{visibilityFailure:true},503],[{listingMissing:true},404],[{workspace:OTHER},404],[{readOnly:true},403],[{deleting:true},409]] as const){
    const r=await invoke({main_photo_asset_id:ASSET},options);assertEquals(r.status,status);
    if(!options.readOnly)assertEquals(r.updates,[]);
  }
});
Deno.test("actual creation cannot preselect an unuploaded or arbitrary property cover",async()=>{
  for(const body of [{main_photo_asset_id:ASSET},{main_photo_key:KEY}]){const r=await invoke(body,{},"POST");assertEquals(r.status,400);assertEquals(r.assetReads,0);assertEquals(r.updates,[]);}
});
Deno.test("actual gallery PATCH selects current uploaded versions and keeps its selected cover",async()=>{
  const r=await invoke({gallery_asset_ids:[ASSET.toUpperCase()],main_photo_asset_id:ASSET});assertEquals(r.status,200);
  assertEquals(r.updates,[{gallery_asset_ids:[ASSET],main_photo_key:KEY}]);
  const omitted=await invoke({main_photo_key:null},{selection:[ASSET]});assertEquals(omitted.status,200);assertEquals(omitted.body.gallery_asset_ids,[ASSET]);assertEquals(omitted.assetReads,0);
});
Deno.test("actual gallery replacement can clear old cover, hide all, or restore legacy selection",async()=>{
  const hidden=await invoke({gallery_asset_ids:[]});assertEquals(hidden.status,200);assertEquals(hidden.updates,[{gallery_asset_ids:[],main_photo_key:null}]);
  const legacy=await invoke({gallery_asset_ids:null},{selection:[ASSET]});assertEquals(legacy.status,200);assertEquals(legacy.updates,[{gallery_asset_ids:null}]);
  const oldCover=await invoke({gallery_asset_ids:[],main_photo_asset_id:ASSET});assertEquals(oldCover.status,400);assertEquals(oldCover.updates,[]);
});
Deno.test("actual gallery PATCH rejects missing, cross-listing, revoked and invalid selections",async()=>{
  for(const gallery_asset_ids of [[ASSET,ASSET.toUpperCase()],["bad"],"bad",Array(41).fill(ASSET),[null]]){
    const r=await invoke({gallery_asset_ids});assertEquals(r.status,400);assertEquals(r.updates,[]);
  }
  for(const options of [{photo:null},{visible:false},{photo:{id:ASSET,listing_id:OTHER,kind:"photo",bucket:"renders",uploaded:true,storage_key:KEY}}]){
    const r=await invoke({gallery_asset_ids:[ASSET]},options);assertEquals(r.status,400);assertEquals(r.updates,[]);
  }
  const wrongCover=await invoke({main_photo_asset_id:ASSET},{selection:[]});assertEquals(wrongCover.status,400);assertEquals(wrongCover.updates,[]);
});
Deno.test("actual cloud gallery addition uses verified caller and atomic append with its optional cover",async()=>{
 const r=await invoke({gallery_add_asset_ids:[ASSET],main_photo_asset_id:ASSET,user_id:OTHER,org_id:OTHER},{selection:[OTHER],existingKey:null});
 assertEquals(r.status,200);assertEquals(r.updates,[]);assertEquals(r.body.gallery_asset_ids,[OTHER,ASSET]);assertEquals(r.body.main_photo_key,KEY);
 assertEquals(r.appends,[{p_user:USER,p_org:ORG,p_listing:LISTING,p_add:[ASSET],p_set_main:true,p_main_photo_key:KEY}]);
 const omitted=await invoke({gallery_add_asset_ids:[ASSET]},{selection:[OTHER]});assertEquals(omitted.status,200);assertEquals(omitted.appends[0].p_set_main,false);assertEquals(omitted.body.main_photo_key,KEY);
 const clear=await invoke({gallery_add_asset_ids:[],main_photo_asset_id:null},{selection:[ASSET]});assertEquals(clear.status,200);assertEquals(clear.appends[0].p_set_main,true);assertEquals(clear.body.main_photo_key,null);
});
Deno.test("actual cloud addition rejects replacement/detail mixes, invalid input and unavailable authority",async()=>{
 for(const body of [{gallery_add_asset_ids:[ASSET],gallery_asset_ids:null},{gallery_add_asset_ids:[ASSET],address:"Cannot partially save"},{gallery_add_asset_ids:null},{gallery_add_asset_ids:[ASSET,ASSET]}]){
  const r=await invoke(body);assertEquals(r.status,"address" in body?426:400);assertEquals(r.appends,[]);assertEquals(r.updates,[]);
 }
 for(const [options,status]of [[{readOnly:true},403],[{workspace:OTHER},404],[{deleting:true},409],[{appendFailure:true},503]]as const){
  const r=await invoke({gallery_add_asset_ids:[ASSET]},options);assertEquals(r.status,status);assertEquals(r.updates,[]);
 }
});

const REMOVE_OP="a0200205-0000-4000-8000-000000000010";
const removalBody=()=>({gallery_remove_asset_ids:[ASSET],gallery_remove_operation_id:REMOVE_OP,expected_gallery_asset_ids:[OTHER,ASSET],expected_main_photo_key:KEY});
Deno.test("actual cloud removal uses saved actor-scoped RPC and preserves unknown selected assets",async()=>{
 const r=await invoke(removalBody(),{selection:[OTHER,ASSET]});assertEquals(r.status,200);assertEquals(r.body.gallery_asset_ids,[OTHER]);assertEquals(r.body.main_photo_key,null);
 assertEquals(r.removals,[{p_user:USER,p_org:ORG,p_listing:LISTING,p_operation:REMOVE_OP,p_remove:[ASSET],p_expected:[OTHER,ASSET],p_expected_main:KEY}]);
 assertEquals(r.updates,[]);assertEquals(r.appends,[]);assertEquals(r.body.gallery_remove.actor_id,USER);assertEquals(r.body.library_org_id,ORG);
 const replay=await invoke(removalBody(),{selection:[OTHER,ASSET],removeReplayed:true});assertEquals(replay.status,200);assertEquals(replay.body.gallery_asset_ids,[OTHER,ASSET]);assertEquals(replay.body.gallery_remove.replayed,true);
});
Deno.test("actual cloud removal rejects missing saved operation snapshot and replacement mixes",async()=>{
 for(const body of [{...removalBody(),gallery_asset_ids:[]},{...removalBody(),main_photo_asset_id:ASSET},{...removalBody(),user_id:OTHER},
  {...removalBody(),gallery_remove_operation_id:"bad"},{...removalBody(),gallery_remove_asset_ids:[]},{...removalBody(),gallery_remove_asset_ids:null},
  {...removalBody(),gallery_remove_asset_ids:[ASSET,ASSET]},{...removalBody(),expected_gallery_asset_ids:[ASSET,ASSET]},
  {...removalBody(),expected_main_photo_key:42},Object.fromEntries(Object.entries(removalBody()).filter(([k])=>k!=="expected_gallery_asset_ids"))]){
  const r=await invoke(body);assertEquals(r.status,400);assertEquals(r.removals,[]);assertEquals(r.updates,[]);
 }
 for(const idempotencyKey of[null,"gallery-remove:"+OTHER]){const r=await invoke(removalBody(),{idempotencyKey});assertEquals(r.status,409);assertEquals(r.removals,[]);}
});
Deno.test("actual cloud removal surfaces stale CAS and never replaces or appends after unknown reply",async()=>{
 const stale=await invoke(removalBody(),{removeError:{code:"PT409",message:"RP409: selection changed"}});assertEquals(stale.status,409);assertEquals(stale.body.code,"gallery_selection_changed");
 for(const removeError of[{message:"Synthetic transport outage"},{message:"RP404: listing unavailable"},{message:"RP403: write denied"}]){
  const r=await invoke(removalBody(),{removeError});assertEquals(r.status,removeError.message.startsWith("RP404")?404:removeError.message.startsWith("RP403")?403:503);assertEquals(r.updates,[]);assertEquals(r.appends,[]);
 }
 for(const removeAck of[{actor_id:OTHER},{operation_id:OTHER},{requested_asset_ids:[OTHER]},{removed_asset_ids:[OTHER]},{removed_asset_ids:[ASSET,ASSET]}]){
  const r=await invoke(removalBody(),{removeAck});assertEquals(r.status,503);assertEquals(r.updates,[]);assertEquals(r.appends,[]);
 }
});
Deno.test("actual cloud removal preserves current role workspace deletion and snapshot authority",async()=>{
 for(const[options,status]of[[{readOnly:true},403],[{workspace:OTHER},404],[{deleting:true},409],[{listingMissing:true},404]]as const){const r=await invoke(removalBody(),options);assertEquals(r.status,status);assertEquals(r.removals,[]);}
 const r=await invoke({}, {},"GET");assertEquals(r.status,200);assertEquals(r.body.gallery_assets,[{asset_id:ASSET,sha256:"a".repeat(64),bytes:1024}]);assertEquals(r.snapshots,[{p_user:USER,p_org:ORG,p_listing:LISTING}]);assertEquals(r.updates,[]);
});
