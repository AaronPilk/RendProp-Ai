import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {privateMediaUrl,privateMediaIdentity,verifyPrivateCapability,privateMediaAuthority} from "./private-media.ts";
import {HttpError} from "./http.ts";
const actor="10000000-0000-4000-8000-000000000001",org="20000000-0000-4000-8000-000000000002",listing="30000000-0000-4000-8000-000000000003",other="40000000-0000-4000-8000-000000000004",key=`renders/${org}/${listing}/photo.jpg`;
async function setup<T>(fn:()=>Promise<T>){const prior=Deno.env.get("MEDIA_GATEWAY_SECRET"),flag=Deno.env.get("PRIVATE_MEDIA_DELIVERY");Deno.env.set("MEDIA_GATEWAY_SECRET","a".repeat(64));Deno.env.set("PRIVATE_MEDIA_DELIVERY","gateway-v1");try{return await fn();}finally{for(const[name,value]of [["MEDIA_GATEWAY_SECRET",prior],["PRIVATE_MEDIA_DELIVERY",flag]])value===undefined?Deno.env.delete(name!):Deno.env.set(name!,value!);}}
async function token(extra:Record<string,unknown>={}){return new URL(await privateMediaUrl({actor,org,listing,bucket:"renders",key,...extra} as any)).pathname.slice(15);}
function admin(fault=""){
 let reads=0,admits=0;const order:string[]=[];
 const rpc=async(name:string,args:any)=>{order.push(name);if(name==="media_delivery_admit"){admits++;assertEquals(args.p_org,org);assertEquals(args.p_required,true);return fault==="budget"?{data:null,error:{message:"RP429: Media serving allowance exhausted"}}:{data:{admitted:true,legacy_unbudgeted:false},error:null};}
 if(name==="hosting_retention_state")return{data:{org_id:org,policy:"preserved",protected:true,retention_ends_at:null,hosting_available:fault!=="retention"},error:null};
 if(name==="studio_presenter_media_visibility")return{data:{assets:{},renders:{},keys:Object.fromEntries(args.p_keys.map((k:string)=>[k,fault!=="withdrawn"]))},error:null};
 if(name==="studio_production_review")return{data:{document:{revision:1,payload:{draft:{narration:{resultId:other}}}},source_revision:1,review:{status:fault==="review"?"draft":"submitted",submitted_at:"2026-10-07"}},error:null};
 throw Error("Unknown RPC "+name);};
 const from=(table:string)=>{reads++;order.push(table);const filters:any={};const q:any={select:()=>q,eq:(k:string,v:any)=>{filters[k]=v;return q;},is:()=>q,in:()=>q,limit:()=>q,maybeSingle:()=>Promise.resolve(reply()),then:(resolve:any)=>Promise.resolve(reply()).then(resolve)};
 function reply(){let data:any=null;if(table==="memberships")data={user_id:actor,org_id:org,role:fault==="membership"?"viewer":"agent"};if(table==="profiles")data={id:actor};if(table==="deletion_requests")data=fault==="deletion"?[{id:other}]:[];if(table==="listings")data={id:listing,org_id:fault==="other-org"?other:org,deleted_at:null};if(table==="capture_assets")data=fault==="unregistered"?null:{id:other,listing_id:listing,bucket:"renders",storage_key:key,uploaded:true};if(["photos","renders","media_provenance"].includes(table))data=[];
 if(table==="studio_project_media")data={id:other,actor_id:actor,org_id:org,bytes:2,parts:1,receipts:{"0":{state:fault==="project"?"writing":"complete",bytes:2,sha256:"c".repeat(64)}}};
 if(table==="studio_creative_results")data={id:other,user_id:other,org_id:org,listing_id:listing,kind:"voice",bucket:"uploads",storage_key:`ai-voice/${org}/${other}.mp3`,metadata:{state:"completed"}};
 return {data,error:null};}return q;};return{rpc,from,stats:()=>({reads,admits,order})};
}
Deno.test("private capability is exact host-only <=600s and rejects tamper/expiry/type/scope",()=>setup(async()=>{
 const value=await token(),url=`https://rendprop.com/private-media/${value}`;const c=await verifyPrivateCapability(value);assertEquals(c.actor,actor);assertEquals(c.key,key);assert(c.exp<=Math.floor(Date.now()/1000)+600);assertEquals(privateMediaIdentity(url),c);
 for(const input of [value.slice(0,-1)+(value.endsWith('a')?'b':'a'),"invalid","",value+".more"])await assertRejects(()=>verifyPrivateCapability(input),HttpError);
 for(const input of [url+"?key=other",url+"#private",url.replace("rendprop.com","attacker.invalid"),url.replace("https:","http:")])assertEquals(privateMediaIdentity(input),null);
 for(const extra of [{actor:[actor]},{org:"invalid",key},{listing:12},{key:"../secret"},{key:"é".repeat(513)},{review:{owner:actor,result:other,revision:2147483647}},{review:{owner:actor,result:other,revision:1,extra:true}}])await assertRejects(()=>token(extra),HttpError);
 await assertRejects(()=>privateMediaUrl({actor,org,listing,bucket:"renders",key},601),HttpError);
 Deno.env.set("PRIVATE_MEDIA_DELIVERY","unknown");await assertRejects(()=>privateMediaUrl({actor,org,listing,bucket:"renders",key}),HttpError);
}));
Deno.test("gateway reads exact registered owned media and meters before any catalog work",()=>setup(async()=>{
 const a=admin(),t=await token();assertEquals(await privateMediaAuthority(a,t,7),{schema:1,slug:"private",objects:{[key]:"renders"},stream_uid:null});assertEquals(a.stats().admits,1);assertEquals(a.stats().order[0],"media_delivery_admit");
 const exhausted=admin("budget");await assertRejects(()=>privateMediaAuthority(exhausted,t,7),HttpError);assertEquals(exhausted.stats().reads,0);
 for(const fault of ["membership","deletion","other-org","unregistered","withdrawn","retention"])await assertRejects(()=>privateMediaAuthority(admin(fault),t,0),HttpError);
}));
Deno.test("project chunk requires exact author and every finalized receipt",()=>setup(async()=>{
 const k=`studio-project/${org}/${actor}/${other}/0`,t=await token({listing:null,bucket:"uploads",key:k});assertEquals((await privateMediaAuthority(admin(),t,2)).objects,{[k]:"uploads"});
 await assertRejects(()=>privateMediaAuthority(admin("project"),t,2),HttpError);
 await assertRejects(async()=>privateMediaAuthority(admin(),await token({listing:null,bucket:"uploads",key:k.replace(actor,other)}),2),HttpError);
}));
Deno.test("review narration rechecks exact submitted revision and selected cross-author result",()=>setup(async()=>{
 const k=`ai-voice/${org}/${other}.mp3`,t=await token({bucket:"uploads",key:k,review:{owner:other,result:other,revision:1}});assertEquals((await privateMediaAuthority(admin(),t,2)).objects,{[k]:"uploads"});
 await assertRejects(()=>privateMediaAuthority(admin("review"),t,2),HttpError);
 await assertRejects(async()=>privateMediaAuthority(admin(),await token({bucket:"uploads",key:k,review:{owner:other,result:other,revision:2}}),2),HttpError);
}));
