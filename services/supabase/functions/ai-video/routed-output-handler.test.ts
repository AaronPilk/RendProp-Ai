// Actual routedStatus + output journal + immutable R2 transport/signers.
// Only provider polling, SQL and storage HTTP boundaries are synthetic; no net.
import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {respondError} from "../_shared/http.ts";
for(const [key,value]of Object.entries({CLOUDFLARE_ACCOUNT_ID:"media-output-fixture",R2_ACCESS_KEY_ID:"synthetic-access",R2_SECRET_ACCESS_KEY:"synthetic-secret"}))Deno.env.set(key,value);
const common=await import("../_shared/providers/common.ts"),r2=await import("../_shared/r2.ts");
const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url)),start=source.indexOf("async function routedStatus("),end=source.indexOf("\n}\n",start);
assert(start>0&&end>start);
const encode=(s:string)=>"data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(s)));
const module=await import(encode(`
 import{json,HttpError}from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
 import{createRoutedOutput}from ${JSON.stringify(new URL("./routed-output.ts",import.meta.url).href)};
 import{asHttpError}from ${JSON.stringify(new URL("../_shared/providers/chain.ts",import.meta.url).href)};
 export function make(deps:any){const adminClient=()=>deps.admin,adapterFor=()=>deps.adapter,headObject=deps.head,persistResult=deps.persist,privateMediaUrl=(scope:any,seconds:number)=>{if(scope.actor!==deps.user||scope.org!==deps.org||scope.listing!==deps.listing||scope.bucket!=="renders"||seconds!==600)throw Error("Exact saved video signing scope required");return deps.sign(scope.key);},R2_BUCKET_RENDERS="rendprop-renders",uncheckedDriftBlock=()=>({status:"unchecked",publishable:false});
 ${source.slice(start,end+3)}
 return routedStatus;}
`));
const org="10000000-0000-4000-8000-000000000001",user="20000000-0000-4000-8000-000000000002",listing="30000000-0000-4000-8000-000000000003";
const job={p:"fal",m:"synthetic-video",i:"owned-provider-job",u:"https://queue.fal.run/synthetic",usr:user,l:listing,k:"reel",t:new Date().toISOString()};
type Row=Record<string,unknown>;
async function fixture(options:{lostWrite?:boolean;deleteDuringSign?:boolean}={},action:(f:any)=>Promise<void>){
 const previous=globalThis.fetch,objects=new Map<string,Uint8Array>(),rows=new Map<string,Row>();let deleted=false,lost=!!options.lostWrite,malformed=false,polls=0,downloads=0,writes=0,signs=0,heads=0,puts=0;
 const admin={from:(table:string)=>{assertEquals(table,"private_ai_outputs");let keys:string[]=[],filters:Record<string,unknown>={};const q:any={select:()=>q,eq:(k:string,v:unknown)=>{filters[k]=v;return q;},is:(k:string,v:unknown)=>{filters[k]=v;return q;},in:(k:string,v:string[])=>{assertEquals(k,"storage_key");keys=v;return q;},limit:async()=>({error:null,data:[...rows.values()].filter(row=>keys.includes(String(row.storage_key))&&(malformed||Object.entries(filters).every(([k,v])=>row[k]===v)))})};return q;},rpc:async(name:string,args:Row)=>{assertEquals(name,"register_private_ai_output");assertEquals([args.p_user,args.p_org,args.p_listing,args.p_bucket],[user,org,listing,"renders"]);if(deleted)return{data:null,error:{message:"actor or listing withdrawn"}};const key=String(args.p_key),prior=rows.get(key);if(prior&&prior.bytes!==args.p_bytes)return{data:null,error:{message:"immutable identity conflict"}};if(!prior)rows.set(key,{org_id:org,user_id:user,listing_id:listing,bucket:"renders",storage_key:key,bytes:args.p_bytes});return{data:{ok:true,key},error:null};}};
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init),url=new URL(req.url);if(url.hostname==="fal.media"){downloads++;return new Response(new Uint8Array([1,2,3,4]),{headers:{"Content-Type":"video/mp4","Content-Length":"4"}});}assertEquals(url.hostname,"media-output-fixture.r2.cloudflarestorage.com");const key=decodeURIComponent(url.pathname.slice("/rendprop-renders/".length));if(req.method==="PUT"){puts++;assertEquals(req.headers.get("if-none-match"),"*");assertEquals(req.redirect,"error");const bytes=new Uint8Array(await req.arrayBuffer());if(objects.has(key))return new Response(null,{status:412});objects.set(key,bytes);writes++;if(lost){lost=false;throw Error("lost write response");}return new Response(null);}assertEquals(req.method,"HEAD");heads++;const bytes=objects.get(key);return new Response(null,{status:bytes?200:404,headers:bytes?{"Content-Length":String(bytes.length),"Content-Type":"video/mp4"}:{}});};
 const handler=module.make({admin,user,org,listing,adapter:{poll:async()=>{polls++;return{status:"done",result_url:"https://fal.media/finished.mp4",mime:"video/mp4"};}},head:r2.headObject,persist:common.persistResult,sign:async(key:string)=>{signs++;const url=await common.persistedUrl(key);if(options.deleteDuringSign)deleted=true;return url;}});
 const invoke=async()=>{try{return await handler(org,job);}catch(e){return respondError(e);}};
 try{await action({invoke,objects,rows,withdraw:()=>deleted=true,malformed:()=>malformed=true,counts:()=>({polls,downloads,writes,signs,heads,puts})});}finally{globalThis.fetch=previous;}
}
Deno.test("actual routed completed refresh reuses one exact journaled object and fresh host-only <=600s capability without provider poll/download",async()=>{
 await fixture({},async f=>{let key="";for(let n=0;n<3;n++){const response=await f.invoke(),body=await response.json();assertEquals(response.status,200);assertEquals(body.status,"completed");if(n)assertEquals(body.asset_key,key);key=body.asset_key;const signed=new URL(body.video_url);assertEquals(signed.searchParams.get("X-Amz-SignedHeaders"),"host");assertEquals(signed.searchParams.get("X-Amz-Expires"),"600");assertEquals(decodeURIComponent(signed.pathname),"/rendprop-renders/"+key);assertEquals(body.drift.publishable,false);}assertEquals(f.objects.size,1);assertEquals(f.rows.size,1);assertEquals({...f.counts(),heads:0},{polls:1,downloads:1,writes:1,signs:3,heads:0,puts:1});});
});
Deno.test("actual routed completed status recovers lost committed PUT without another poll, download or object",async()=>{
 await fixture({lostWrite:true},async f=>{assertEquals((await f.invoke()).status,503);const response=await f.invoke();assertEquals(response.status,200);assert((await response.json()).video_url);assertEquals(f.objects.size,1);assertEquals(f.rows.size,1);assertEquals(f.counts().polls,1);assertEquals(f.counts().downloads,1);assertEquals(f.counts().puts,1);});
});
Deno.test("actual concurrent routed completion uses immutable same-object CAS, then cached reads avoid provider work",async()=>{
 await fixture({},async f=>{const responses=await Promise.all([f.invoke(),f.invoke()]);const bodies=await Promise.all(responses.map(r=>r.json()));assertEquals(responses.map(r=>r.status),[200,200]);assertEquals(bodies[0].asset_key,bodies[1].asset_key);assertEquals(f.objects.size,1);assertEquals(f.rows.size,1);assertEquals(f.counts().writes,1);const before=f.counts();assertEquals((await f.invoke()).status,200);assertEquals(f.counts().downloads,before.downloads);assertEquals(f.counts().polls,before.polls);});
});
Deno.test("actual concurrent completion with a lost write response still commits one object and recovers only that output",async()=>{
 await fixture({lostWrite:true},async f=>{const responses=await Promise.all([f.invoke(),f.invoke()]);assertEquals(responses.map(r=>r.status).sort(),[200,503]);assertEquals(f.objects.size,1);assertEquals(f.rows.size,1);assertEquals(f.counts().writes,1);const before=f.counts();assertEquals((await f.invoke()).status,200);assertEquals(f.counts().downloads,before.downloads);assertEquals(f.counts().polls,before.polls);});
});
Deno.test("actual saved routed output refuses foreign journal identity, deletion, mismatched stored bytes and withdrawal during fresh signing",async()=>{
 await fixture({},async f=>{assertEquals((await f.invoke()).status,200);f.malformed();const row=[...f.rows.values()][0];row.user_id=org;const before=f.counts();const response=await f.invoke();assertEquals(response.status,503);assert(!JSON.stringify(await response.json()).includes("X-Amz-"));assertEquals(f.counts().heads,before.heads);assertEquals(f.counts().polls,before.polls);});
 await fixture({},async f=>{assertEquals((await f.invoke()).status,200);f.withdraw();assertEquals((await f.invoke()).status,503);assertEquals(f.counts().polls,1);});
 await fixture({},async f=>{assertEquals((await f.invoke()).status,200);const key=[...f.objects.keys()][0];f.objects.set(key,new Uint8Array([1]));assertEquals((await f.invoke()).status,503);assertEquals(f.counts().signs,1);});
 await fixture({deleteDuringSign:true},async f=>{const response=await f.invoke();assertEquals(response.status,503);assert(!JSON.stringify(await response.json()).includes("X-Amz-"));});
});
