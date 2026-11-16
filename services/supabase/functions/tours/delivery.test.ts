import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
Deno.env.set("R2_PUBLIC_BASE_URL","https://media.fixture.invalid");
Deno.env.set("PUBLIC_MEDIA_DELIVERY","proxy-v1");
const { deliveryEnvelope, admittedFloorplan, admittedBusinessLogo, legacyObjectKey, businessLogoDelivery, publishedListingDetails } = await import("./delivery.ts");
import { HttpError } from "../_shared/http.ts";
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",id="30000000-0000-4000-8000-000000000003",key=`renders/${org}/${listing}/floorplan.jpg`,scope={orgId:org,listingId:listing};
Deno.test("delivery envelope admits exact selected identities and refuses prefix-shaped nonidentities",()=>{
 const d=deliveryEnvelope("fixture",scope,[key,key],"a".repeat(32));assertEquals(d.objects,{[key]:"renders"});assertEquals(d.stream_uid,"a".repeat(32));
 for(const invalid of [key.replace(listing,id),`${key}/../../private`,`https://media.invalid/${key}`,`ai-router/${org}/unpublished/output.mp4`,`${key}?other=1`])assertThrows(()=>deliveryEnvelope("fixture",scope,[invalid],null),HttpError);
 assertEquals(deliveryEnvelope("fixture",scope,[],"not-a-Stream-UID").stream_uid,null);
});
function database(row:Record<string,unknown>|null,visible=true,failure=false){return {from:(_table:string)=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>({data:row,error:failure?{message:"private DB error"}:null})};return q;},rpc:(_name:string,args:Record<string,unknown>)=>Promise.resolve({data:{assets:Object.fromEntries((args.p_assets as string[]).map(v=>[v,visible])),renders:{},keys:Object.fromEntries((args.p_keys as string[]).map(v=>[v,visible]))},error:null})};}
Deno.test("floorplans must map to an exact uploaded same-property DB asset plus current approval",async()=>{
 Deno.env.set("R2_PUBLIC_BASE_URL","https://media.fixture.invalid");
 // publicR2Url was captured at import, so use its configured base for the real legacy mapper.
 const {publicR2Url}=await import("../_shared/r2.ts");const url=publicR2Url(key);
 assert(url);
 Deno.env.set("R2_PUBLIC_BASE_URL",new URL(url).origin);
 const base={id,listing_id:listing,kind:"photo",bucket:"renders",storage_key:key,uploaded:true};
 const refs={assets:[] as string[],keys:[] as string[]};assert(await admittedFloorplan(database(base),scope,url,"fixture",refs));assertEquals(refs,{assets:[id],keys:[key]});
 for(const row of [null,{...base,storage_key:key+".other"},{...base,listing_id:id},{...base,uploaded:false},{...base,bucket:"uploads"},{...base,kind:"video"}])assertEquals(await admittedFloorplan(database(row),scope,url,"fixture",{assets:[],keys:[]}),null);
 assertEquals(await admittedFloorplan(database(base,false),scope,url,"fixture",{assets:[],keys:[]}),null);
 await assertRejects(()=>admittedFloorplan(database(base,true,true),scope,url,"fixture",{assets:[],keys:[]}),HttpError);
});
Deno.test("logo delivery requires exact current published journal identity",async()=>{
 const logo=`renders/${org}/brand/${id}.png`,url="https://legacy.fixture.invalid/"+logo,base={org_id:org,object_key:logo,public_url:url,state:"published"};
 const admitted=await admittedBusinessLogo(database(base),org,url,"fixture");
 // A missing public delivery origin can safely suppress the URL; it never authorizes a key alone.
 assert(admitted);assertEquals(admitted.key,logo);
 for(const row of [null,{...base,state:"retired"},{...base,org_id:listing},{...base,public_url:url+"x"},{...base,object_key:logo.replace(org,listing)}])assertEquals(await admittedBusinessLogo(database(row),org,url,"fixture"),null);
 await assertRejects(()=>admittedBusinessLogo(database(base,true,true),org,url,"fixture"),HttpError);
});

Deno.test("standalone business-logo bytes require exact current journal pointer and survive no stale publication",async()=>{
 const key=`renders/${org}/brand/${id}.png`,url="https://media.fixture.invalid/"+key,owner={id:org,deleted_at:null,brand_kit:{business_logo_url:url}},asset={org_id:org,object_key:key,state:"published",public_url:url};
 const fixture=(opts:{retired?:boolean;changed?:boolean;foreign?:boolean;deleted?:boolean}={})=>{let reads=0;return{rpc:async()=>({error:null,data:{org_id:org,policy:"preserved",protected:false,retention_ends_at:null,hosting_available:true}}),from:(table:string)=>{const q={select:()=>q,eq:()=>q,is:()=>q,maybeSingle:async()=>{if(table==="orgs"){reads++;return{error:null,data:opts.deleted?null:opts.changed&&reads>1?{...owner,brand_kit:{business_logo_url:null}}:owner};}return{error:null,data:{...asset,...(opts.retired?{state:"retired"}:{}),...(opts.foreign?{org_id:listing}:{})}};}};return q;}};};
 assertEquals(await businessLogoDelivery(fixture(),org,key),{schema:1,slug:org,objects:{[key]:"renders"},stream_uid:null});
 for(const opts of [{retired:true},{changed:true},{foreign:true},{deleted:true}])await assertRejects(()=>businessLogoDelivery(fixture(opts),org,key),HttpError);
 await assertRejects(()=>businessLogoDelivery(fixture(),org,key.replace(org,listing)),HttpError);
});
Deno.test("duplicated legacy details media cannot bypass exact selected public identity mapping",()=>{
 const selected="https://media.fixture.invalid/"+key,retired=selected+"retired",details={gallery:[{url:selected},{url:retired}],floorplan:{image_url:retired},reel_url:retired,external:"https://external.fixture.invalid/image"};
 const mapped=publishedListingDetails(details,"fixture",[key]);assertEquals((mapped.gallery as {url:string|null}[])[0].url,`https://rendprop.com/media/fixture/r2/${encodeURIComponent(key)}`);assertEquals((mapped.gallery as {url:string|null}[])[1].url,null);assertEquals(mapped.reel_url,null);assertEquals(mapped.external,details.external);assertEquals(details.gallery[1].url,retired);
});
