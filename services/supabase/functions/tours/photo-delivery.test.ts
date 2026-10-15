import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
// Scope import-time client configuration; no fixture setting leaks to others.
const env={SUPABASE_URL:"https://photo-delivery-fixture.invalid",SUPABASE_ANON_KEY:"fixture",SUPABASE_SERVICE_ROLE_KEY:"fixture",CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"fixture",R2_SECRET_ACCESS_KEY:"fixture"};
const before=Object.fromEntries(Object.keys(env).map(k=>[k,Deno.env.get(k)]));
for(const [k,v]of Object.entries(env))Deno.env.set(k,v);
let photoDelivery:typeof import("./photo-delivery.ts").photoDelivery;
try{({photoDelivery}=await import("./photo-delivery.ts"));}finally{for(const [k,v]of Object.entries(before))v===undefined?Deno.env.delete(k):Deno.env.set(k,v);}
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",render="30000000-0000-4000-8000-000000000003",asset="40000000-0000-4000-8000-000000000004",other="50000000-0000-4000-8000-000000000005";
const key=`renders/${org}/${listing}/gallery-${asset}-complete-version.jpg`,slug="fixture-gallery";
type Options={legacy?:boolean;outsideFirst100?:boolean;cover?:boolean;empty?:boolean;unselected?:boolean;crossProperty?:boolean;notUploaded?:boolean;disclosure?:boolean;disclosureLate?:boolean;disclosureError?:boolean;badMime?:boolean;oversize?:boolean;changedRender?:boolean;deleted?:boolean;changedSelection?:boolean;changedCover?:boolean;changedPhoto?:boolean;revoked?:boolean;badVisibility?:boolean;expired?:boolean;hostingLate?:boolean};
function fixture(o:Options={}){
 const counts:Record<string,number>={},calls:string[]=[];const count=(s:string)=>(counts[s]=(counts[s]??0)+1);
 const db={from(table:string){const filters:Record<string,unknown>={};let fields="";const q={select(s:string){fields=s;return q;},eq(k:string,v:unknown){filters[k]=v;return q;},not(){return q;},like(){return q;},order(){return q;},limit(){return q;},maybeSingle(){return run();},then(resolve:any,reject:any){return run().then(resolve,reject);}};
 async function run(){calls.push(table);const n=count(table+(table==="capture_assets"&&fields==="id"?"_window":""));let data:any;
  if(table==="renders")data=o.changedRender&&n>1?null:{id:render,listing_id:listing,slug,published_at:"2026-10-15T00:00:00Z"};
  else if(table==="listings")data={id:listing,org_id:org,deleted_at:o.deleted&&n>1?"2026-10-15":null,main_photo_key:o.changedCover&&n>1?"other":o.cover?key:null,gallery_asset_ids:o.changedSelection&&n>1?[other]:o.empty?[]:o.legacy?null:o.unselected?[other]:[asset]};
  else if(table==="media_provenance"){if(o.disclosureError)return{data:null,error:{message:"fixture"}};data=o.disclosure||o.disclosureLate&&n>1?[{id:other}]:[];}
  else if(table==="capture_assets"&&fields==="id")data=o.outsideFirst100?[{id:other}]:[{id:asset}];
  else if(table==="capture_assets"){assertEquals(filters,{listing_id:listing,storage_key:key});data={id:asset,listing_id:o.crossProperty?other:listing,storage_key:key,kind:"photo",bucket:"renders",uploaded:!o.notUploaded,upload_aborted:false,bytes:o.oversize?20_000_001:5_180_000,content_type:o.badMime?"video/mp4":"image/jpeg",created_at:o.changedPhoto&&n>1?"2026-10-15T01:00:00Z":"2026-10-15T00:00:00Z"};}
  else throw Error("Unrelated public read: "+table);
  return{data,error:null};}return q;},async rpc(name:string,args:any){calls.push(name);const n=count(name);
  if(name==="hosting_retention_state")return{data:{org_id:org,policy:o.expired||o.hostingLate&&n>1?"prospective_90_day_grace":"preserved",protected:false,retention_ends_at:o.expired||o.hostingLate&&n>1?"2020-01-01T00:00:00Z":null,hosting_available:!(o.expired||o.hostingLate&&n>1)},error:null};
  if(name==="media_delivery_admit"){assertEquals(args,{p_org:org,p_bytes:270000,p_required:true});return{data:{admitted:true,legacy_unbudgeted:false,basis:"product_media_serving",financial_budget_bypassed:true,infrastructure_cost:"unpriced",request_counted:true,bytes_counted:270000},error:null};}
  if(name==="studio_presenter_media_visibility"){assertEquals(args,{p_listing:listing,p_assets:[asset],p_renders:[render],p_keys:[key]});return{data:Object.fromEntries(["assets","renders","keys"].map(k=>[k,o.badVisibility?{}:Object.fromEntries(args[`p_${k}`].map((v:string)=>[v,!(o.revoked&&n>1)]))])),error:null};}
  throw Error("Unrelated RPC "+name);}};return{db,counts,calls};
}
async function oracle(fn=photoDelivery){const f=fixture();assertEquals(await fn(f.db,slug,key,270000),{schema:1,slug,objects:{[key]:"renders"},stream_uid:null});assertEquals(f.counts.renders,2);assertEquals(f.counts.listings,2);assertEquals(f.counts.capture_assets,2);assertEquals(f.counts.studio_presenter_media_visibility,2);assertEquals(f.counts.hosting_retention_state,2);assertEquals(f.counts.media_delivery_admit,1);assertEquals(f.counts.media_provenance,2);}
Deno.test("thumbnail authority reads only exact current selected photo, returns closed single-image envelope and unpriced bytes",()=>oracle());
Deno.test("legacy first100 or explicit cover remains eligible while empty/retired selections are refused",async()=>{
 for(const o of[{legacy:true},{legacy:true,cover:true,outsideFirst100:true}])assert(await photoDelivery(fixture(o).db,slug,key,270000));
 for(const o of[{legacy:true,outsideFirst100:true},{empty:true},{unselected:true}])await assertRejects(()=>photoDelivery(fixture(o).db,slug,key,270000));
});
Deno.test("exact published render, selected/cover snapshot, source identity and final hosting/visibility revocations fail closed",async()=>{
 for(const o of[{changedRender:true},{deleted:true},{changedSelection:true},{changedCover:true},{changedPhoto:true},{crossProperty:true},{notUploaded:true},{revoked:true},{badVisibility:true},{expired:true},{hostingLate:true}])await assertRejects(()=>photoDelivery(fixture(o).db,slug,key,270000));
});
Deno.test("matching disclosures, late disclosures and unsupported legacy image shapes delegate unchanged generic authority",async()=>{
 for(const o of[{disclosure:true},{disclosureLate:true},{disclosureError:true},{badMime:true},{oversize:true}])assertEquals(await photoDelivery(fixture(o).db,slug,key,270000),null);
 assertEquals(await photoDelivery(fixture().db,slug,`renders/${org}/${other}/gallery-x.jpg`,270000),null);
 for(const bytes of[-1,2*1024*1024+1,NaN])await assertRejects(()=>photoDelivery(fixture().db,slug,key,bytes));
});
Deno.test("compiled omission controls are rejected by the same actual authority/snapshot oracle",async()=>{
 const original=await Deno.readTextFile(new URL("./photo-delivery.ts",import.meta.url));
 for(const [from,to,mode]of[
  ['  await Promise.all([assertMediaVisible(admin,listing.id,refs),assertHostingAvailable(admin,listing.org_id)]);','  // removed final authority','revoked'],
  ['JSON.stringify(currentListing)!==JSON.stringify(listing)','false','changedSelection'],
  ['await admitMediaRead(admin,listing.org_id,bytes);','// omitted metering','meter'],
 ] as const){assertEquals(original.split(from).length,2);const source=original.replace(from,to).replace(/from "(\.\.?\/[^\"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,new URL("./photo-delivery.ts",import.meta.url)).href)}`);const fn=(await import(`data:application/typescript;base64,${btoa(source)}`)).photoDelivery;
  if(mode==="meter")await assertRejects(()=>oracle(fn));else{let allowed=false;try{await fn(fixture({[mode]:true}).db,slug,key,270000);allowed=true;}catch{}assert(allowed,"Mutant did not exercise missing guard");await assertRejects(()=>photoDelivery(fixture({[mode]:true}).db,slug,key,270000));}
 }
});
