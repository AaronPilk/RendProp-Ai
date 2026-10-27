import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {fixture,object,type Fixture,type Row} from "./upload_route_fixture.ts";
const actor="a1111111-1111-4111-8111-111111111111", org="b2222222-2222-4222-8222-222222222222", listing="c3333333-3333-4333-8333-333333333333", asset="d4444444-4444-4444-8444-444444444444";
type Config={reservation?:Row|null;asset?:Row;userStatus?:number;denyWriteAt?:number;failReservation?:boolean;headMissing?:boolean;wrongEtag?:boolean;specPatch?:Row;reservationPatch?:Row};
async function scenario(run:(f:Fixture,stats:{reservations:number;adminAssetReads:number;writeChecks:number})=>Promise<void>,config:Config={}){
 await fixture(async f=>{
  const key=`renders/${org}/${listing}/gallery-${asset}.jpg`;
  Object.assign(f.asset!,{id:asset,storage_key:key,kind:"photo",bucket:"renders",content_type:"image/jpeg",...config.asset});
  f.objects.clear();f.objects.set(`_staging/${key}`,object("AAAA",4,"image/jpeg"));
  if(config.headMissing)f.objects.clear();
  if(config.wrongEtag)f.objects.set(`_staging/${key}`,{...object("AAAA",4,"image/jpeg"),etag:'"changed"'});
  const a=f.asset!,spec=Object.fromEntries(["listing_id","kind","bucket","bytes","content_type","content_type_declared","part_size","parts_total"].map(k=>[k,a[k]]));spec.key_role="gallery";
  const reservation=config.reservation===undefined?{asset_id:asset,actor_id:actor,org_id:org,listing_id:listing,state:"open",spec}:config.reservation;
  if(reservation){Object.assign(reservation,config.reservationPatch??{});Object.assign(reservation.spec as Row,config.specPatch??{});}
  const old=globalThis.fetch,stats={reservations:0,adminAssetReads:0,writeChecks:0};
  globalThis.fetch=async(input,init)=>{
   const req=new Request(input,init),u=new URL(req.url),isService=req.headers.get("authorization")==="Bearer fixture-service";
   if(u.hostname==="upload-fixture.invalid"){
    if(u.pathname==="/rest/v1/capture_assets"&&req.method==="GET"){
     if(!isService){if(config.userStatus)return Response.json({message:"synthetic lookup failure"},{status:config.userStatus});return Response.json([]);}
     stats.adminAssetReads++;
    }
    if(u.pathname==="/rest/v1/upload_reservations"){
     stats.reservations++;assert(isService);assertEquals(req.method,"GET");assertEquals(u.searchParams.get("asset_id"),"eq."+asset);assertEquals(u.searchParams.get("actor_id"),"eq."+actor);
     if(config.failReservation)return Response.json({message:"synthetic query outage"},{status:400});
     return Response.json(reservation===null?[]:[reservation]);
    }
    if(u.pathname==="/rest/v1/rpc/listing_library_scope"){
     stats.writeChecks++;if(config.denyWriteAt===stats.writeChecks){const response=await old(req),body=await response.json();body.can_write=false;return Response.json(body);}
    }
   }
   const response=await old(req);if(u.pathname==="/rest/v1/rpc/settle_upload_reservation"&&f.asset?.uploaded&&reservation)reservation.state="completed";return response;
  };
  try{await run(f,stats);}finally{globalThis.fetch=old;}
 });
}
Deno.test("actual completion resumes owned presenter-hidden stored master without a new upload",()=>scenario(async(f,s)=>{
 const beforeBudget={...f.budget};const r=await f.request("complete",{sha256:"a".repeat(64)});assertEquals(r.status,200,await r.clone().text());const result=await r.json();assertEquals(result.id,asset);assertEquals(f.asset!.uploaded,true);assertEquals(f.copies.length,1);assertEquals(f.charges,[]);assertEquals(f.deletes,[]);assertEquals(s.reservations,1);assertEquals(s.writeChecks,2);assertEquals(f.budget.spent-beforeBudget.spent,4);
 // A lost completion reply is read back through the SAME reservation, not another physical copy.
 const r2=await f.request("complete");assertEquals(r2.status,200);assertEquals(f.copies.length,1);assertEquals(f.charges,[]);
}));
Deno.test("no reservation does not bypass a hidden asset",()=>scenario(async(f,s)=>{assertEquals((await f.request("complete")).status,404);assertEquals(s.adminAssetReads,0);assertEquals(f.copies,[]);},{reservation:null}));
for(const [name,changed]of Object.entries({foreignActor:{actor_id:"f5555555-5555-4555-8555-555555555555"},foreignAsset:{asset_id:"f5555555-5555-4555-8555-555555555555"},cancelled:{state:"cancelled"},invalidOrg:{org_id:"not-an-org"},arraySpec:{spec:[]}})){
 Deno.test("hidden completion refuses "+name,()=>scenario(async(f,s)=>{assertEquals((await f.request("complete")).status,404);assertEquals(s.adminAssetReads,0);assertEquals(f.copies,[]);},{reservation:{asset_id:asset,actor_id:actor,org_id:org,listing_id:listing,state:"open",spec:{},...changed}}));
}
Deno.test("reservation outage fails closed before storage",()=>scenario(async(f)=>{assertEquals((await f.request("complete")).status,503);assertEquals(f.copies,[]);},{failReservation:true}));
Deno.test("user lookup errors are not transformed into privileged fallback",()=>scenario(async(f,s)=>{assertEquals((await f.request("complete")).status,400);assertEquals(s.reservations,0);assertEquals(f.copies,[]);},{userStatus:400}));
for(const action of["renew","abort","part-urls"]){Deno.test("hidden "+action+" has no completion fallback",()=>scenario(async(f,s)=>{assertEquals((await f.request(action)).status,404);assertEquals(s.reservations,0);assertEquals(f.copies,[]);}));}
for(const at of[1,2])Deno.test("fresh write authority refuses at boundary "+at,()=>scenario(async(f)=>{assertEquals((await f.request("complete")).status,403);assertEquals(f.copies,[]);assertEquals(f.asset!.uploaded,false);},{denyWriteAt:at}));
for(const [name,changed]of Object.entries({legacy:{transport_version:1},aborted:{upload_aborted:true},differentListing:{listing_id:"e5555555-5555-4555-8555-555555555555"},differentKey:{storage_key:`renders/${org}/${listing}/gallery-e5555555-5555-4555-8555-555555555555.jpg`}})){
 Deno.test("hidden completion refuses "+name+" even with owned record",()=>scenario(async(f)=>{assertEquals((await f.request("complete")).status,409);assertEquals(f.copies,[]);},{asset:changed}));
}
Deno.test("missing physical transfer retains unchanged completion refusal",()=>scenario(async f=>{assertEquals((await f.request("complete")).status,400);assertEquals(f.copies,[]);assertEquals(f.asset!.uploaded,false);},{headMissing:true}));
Deno.test("wrong physical ETag retains unchanged completion refusal",()=>scenario(async f=>{assertEquals((await f.request("complete")).status,400);assertEquals(f.copies,[]);assertEquals(f.asset!.uploaded,false);},{wrongEtag:true}));

for(const [name,patch]of Object.entries({bytes:{bytes:5},bucket:{bucket:"uploads"},kind:{kind:"video"},declaredType:{content_type:"image/png"},listing:{listing_id:"e5555555-5555-4555-8555-555555555555"},keyRole:{key_role:"original"}})){
 Deno.test("original reservation specification refuses changed "+name,()=>scenario(async f=>{assertEquals((await f.request("complete")).status,409);assertEquals(f.copies,[]);assertEquals(f.charges,[]);},{specPatch:patch}));
}
Deno.test("open reservation cannot certify an already-uploaded hidden asset",()=>scenario(async f=>{assertEquals((await f.request("complete")).status,409);assertEquals(f.copies,[]);},{asset:{uploaded:true}}));
Deno.test("foreign reservation org is not replaced by a visible listing scope",()=>scenario(async(f,s)=>{assertEquals((await f.request("complete")).status,404);assertEquals(s.adminAssetReads,0);assertEquals(f.copies,[]);},{reservationPatch:{org_id:"e5555555-5555-4555-8555-555555555555"}}));
