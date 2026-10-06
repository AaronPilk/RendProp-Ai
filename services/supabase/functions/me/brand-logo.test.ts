import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import jpeg from "npm:jpeg-js@0.4.4";
import {brandImage,MAX_LOGO_BYTES} from "./brand-image.ts";
import {brandLogo} from "./brand-logo.ts";
import {buildAgentCard} from "../_shared/agentcard.ts";
import {HttpError} from "../_shared/http.ts";
const ACTOR="b0100501-0000-4000-8000-000000000001",ORG="b0100501-0000-4000-8000-000000000002",OP="b0100502-0000-4000-8000-000000000001";
function base64(bytes:Uint8Array){let result="";for(const byte of bytes)result+=String.fromCharCode(byte);return btoa(result);}
function crc(bytes:Uint8Array){let n=0xffffffff;for(const b of bytes){n^=b;for(let i=0;i<8;i++)n=(n>>>1)^(n&1?0xedb88320:0);}return(n^0xffffffff)>>>0;}
function chunk(type:string,data:Uint8Array){const out=new Uint8Array(data.length+12),view=new DataView(out.buffer);view.setUint32(0,data.length);out.set(new TextEncoder().encode(type),4);out.set(data,8);view.setUint32(out.length-4,crc(out.subarray(4,out.length-4)));return out;}
async function png(width=1,height=1,raw=new Uint8Array([0,30,40,50,255]),metadata=false){const header=new Uint8Array(13),view=new DataView(header.buffer);view.setUint32(0,width);view.setUint32(4,height);header[8]=8;header[9]=6;const packed=new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer());const parts=[new Uint8Array([137,80,78,71,13,10,26,10]),chunk("IHDR",header),...(metadata?[chunk("tEXt",new TextEncoder().encode("Comment\0PRIVATE_METADATA location"))]:[]),chunk("IDAT",packed),chunk("IEND",new Uint8Array())];const output=new Uint8Array(parts.reduce((n,p)=>n+p.length,0));let offset=0;for(const part of parts){output.set(part,offset);offset+=part.length;}return output;}
function req(image:string,extra:Record<string,unknown>={},clear=false){return new Request("https://fixture.invalid/me/brand/logo"+(clear?"/clear":""),{method:"POST",headers:{"content-type":"application/json","X-Org-Id":ORG},body:JSON.stringify(clear?{expected_logo_url:null,...extra}:{image_base64:image,content_type:"image/png",expected_logo_url:null,client_operation_id:OP,...extra})});}
function fixture(options:Record<string,unknown>={}){
 const calls:any[]=[],writes:any[]=[],objects=new Map<string,any>();let published=false;
 const admin={rpc:async(name:string,args:any)=>{calls.push({name,args});if(name==="prepare_org_brand_logo"){const key=`renders/${ORG}/brand/${OP}.png`;return{error:null,data:{org_id:options.wrongOrg?ACTOR:ORG,actor_id:ACTOR,object_key:key,public_url:`https://cdn.fixture.invalid/${key}`,dispatch:!published&&!options.observeOnly,replayed:published}};}if(name==="publish_org_brand_logo"){if(options.revoked)return{data:null,error:{message:"RP403: role revoked"}};published=true;return{error:null,data:{org_id:ORG,business_logo_url:`https://cdn.fixture.invalid/renders/${ORG}/brand/${OP}.png`}};}if(name==="clear_org_brand_logo")return{error:null,data:{org_id:ORG,business_logo_url:null}};throw Error("Unexpected RPC "+name);}};
 const storage={publicURL:(key:string)=>options.unconfigured?null:`https://cdn.fixture.invalid/${key}`,write:async(key:string,bytes:Uint8Array,type:string,hash:string)=>{writes.push({key,bytes:bytes.length,type,hash});if(options.writeFailure)throw new HttpError(503,"synthetic unavailable");objects.set(key,{bytes:bytes.length,type,sha256:hash,etag:'"synthetic-etag"'});},inspect:async(key:string)=>{const object=objects.get(key);return object?{...object,bytes:options.wrongBytes?1:object.bytes}:null;}};
 return{calls,writes,objects,admin,storage};
}
Deno.test("real PNG verification strips metadata, checks CRC and exact bounded raster scanlines",async()=>{
 const withMeta=await png(1,1,undefined,true),clean=await brandImage(base64(withMeta),"image/png");
 assert(!new TextDecoder().decode(clean.bytes).includes("PRIVATE_METADATA"));assertEquals(clean.type,"image/png");assertEquals(clean.sha256.length,64);
 const corrupt=withMeta.slice();corrupt[corrupt.length-1]^=1;await assertRejects(()=>brandImage(base64(corrupt),"image/png"),HttpError);
 for(const input of [await png(1025,1),await png(1,1,new Uint8Array(32768)),await png(1,1,new Uint8Array([5,30,40,50,255]))])await assertRejects(()=>brandImage(base64(input),"image/png"),HttpError);
});
Deno.test("real JPEG decoder reencodes pixels without comments, EXIF or arbitrary type bodies",async()=>{
 const bytes=jpeg.encode({width:2,height:2,data:new Uint8Array(16).fill(255),comments:["PRIVATE_METADATA location"]},90).data;
 const clean=await brandImage(base64(bytes),"image/jpeg");assert(!new TextDecoder().decode(clean.bytes).includes("PRIVATE_METADATA"));assertEquals(jpeg.decode(clean.bytes).width,2);
 for(const [input,type]of [[base64(new TextEncoder().encode("<svg onload='x'>")),"image/png"],[base64(bytes),"image/svg+xml"],[base64(new Uint8Array(MAX_LOGO_BYTES+1)),"image/jpeg"],["not-base64!","image/jpeg"]])await assertRejects(()=>brandImage(input,type),HttpError);
});
Deno.test("raster input rejects noncanonical unused base64 padding bits",async()=>{
 const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";let encoded="";
 for(let n=1;n<4&&!encoded.endsWith("=");n++)encoded=base64(jpeg.encode({width:2,height:2,data:new Uint8Array(16).fill(255),comments:["x".repeat(n)]},90).data);
 assert(encoded.endsWith("="));const padding=encoded.endsWith("==")?2:1,index=encoded.length-padding-1;
 const invalid=encoded.slice(0,index)+alphabet[alphabet.indexOf(encoded[index])+1]+encoded.slice(index+1);
 assertEquals(atob(invalid),atob(encoded));await brandImage(encoded,"image/jpeg");
 await assertRejects(()=>brandImage(invalid,"image/jpeg"),HttpError);
});
Deno.test("actual logo handler binds verified actor/org, sanitized actual bytes, original CAS and immutable object before publish",async()=>{
 const image=base64(await png(1,1,undefined,true)),f=fixture();const response=await brandLogo(req(image),f.admin,ACTOR,ORG,f.storage);
 assertEquals(response.status,200);assertEquals((await response.json()).org_id,ORG);
 assertEquals(f.calls.map(c=>c.name),["prepare_org_brand_logo","publish_org_brand_logo"]);
 assertEquals(f.calls[0].args.p_actor,ACTOR);assertEquals(f.calls[0].args.p_org,ORG);assertEquals(f.calls[0].args.p_expected,null);assertEquals(f.calls[0].args.p_operation,OP);
 assertEquals(f.calls[0].args.p_bytes,f.writes[0].bytes);assertEquals(f.calls[0].args.p_sha256,f.writes[0].hash);assertEquals(f.calls[0].args.p_url,`https://cdn.fixture.invalid/renders/${ORG}/brand/${OP}.png`);
 assertEquals(f.calls[1].args.p_etag,'"synthetic-etag"');
 const replay=await brandLogo(req(image),f.admin,ACTOR,ORG,f.storage);assertEquals((await replay.json()).replayed,true);assertEquals(f.writes.length,1);
});
Deno.test("actual logo handler refuses input/receipt substitution before any physical write",async()=>{
 const image=base64(await png());for(const options of [{wrongOrg:true},{unconfigured:true}]){const f=fixture(options);await assertRejects(()=>brandLogo(req(image),f.admin,ACTOR,ORG,f.storage),HttpError);assertEquals(f.writes,[]);}
 for(const extra of [{actor_id:"someone"},{public_url:"https://evil.fixture.invalid"},{client_operation_id:"bad"},{content_type:"image/svg+xml"}]){const f=fixture();await assertRejects(()=>brandLogo(req(image,extra),f.admin,ACTOR,ORG,f.storage),HttpError);assertEquals(f.writes,[]);assertEquals(f.calls,[]);}
});
Deno.test("held storage boundary role revocation cannot publish or overwrite an earlier public logo",async()=>{
 const f=fixture({revoked:true}),old=`renders/${ORG}/brand/old.png`;f.objects.set(old,{sha256:"old immutable raster"});
 const image=base64(await png());await assertRejects(()=>brandLogo(req(image),f.admin,ACTOR,ORG,f.storage),HttpError,"role revoked");
 assertEquals(f.writes.length,1);assertEquals(f.objects.get(old),{sha256:"old immutable raster"});assertEquals(f.calls.at(-1).name,"publish_org_brand_logo");
});
Deno.test("unconfirmed/mismatched/failed storage keeps publication closed and does not retry PUT",async()=>{
 const image=base64(await png());for(const options of [{observeOnly:true},{wrongBytes:true},{writeFailure:true}]){const f=fixture(options);await assertRejects(()=>brandLogo(req(image),f.admin,ACTOR,ORG,f.storage),HttpError);assertEquals(f.calls.map(c=>c.name),["prepare_org_brand_logo"]);assertEquals(f.writes.length,options.observeOnly?0:1);}
});
Deno.test("logo clear uses the dedicated RPC and public card publishes logo separately from portrait",async()=>{
 const f=fixture();assertEquals((await brandLogo(req("",{expected_logo_url:"https://cdn.fixture.invalid/current.png"},true),f.admin,ACTOR,ORG,f.storage,"clear")).status,200);
 assertEquals(f.calls,[{name:"clear_org_brand_logo",args:{p_actor:ACTOR,p_org:ORG,p_expected:"https://cdn.fixture.invalid/current.png"}}]);assertEquals(f.writes,[]);
 const card=buildAgentCard({name:"Owner",avatar_url:"https://portrait.fixture.invalid/a.jpg",business_logo_url:"https://cdn.fixture.invalid/logo.png",private_key:"must be omitted"},{});
 assertEquals(card.avatar_url,"https://portrait.fixture.invalid/a.jpg");assertEquals(card.business_logo_url,"https://cdn.fixture.invalid/logo.png");assertEquals(card.private_key,undefined);
});

// Run the exact current /me route and brand patch bodies. Only verified Auth,
// database RPC, quota and physical storage boundaries are synthetic.
async function routeFixture(dropRoleGate=false){
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const start=source.indexOf("Deno.serve(async (req) => {"),end=source.indexOf("\n});",start)+5;
 let handler=source.slice(start,end).trimEnd().replace("Deno.serve(async (req) => {","export const handler=async(req:Request)=>{").replace(/\n\}\);$/,"\n};");
 const roleGate='assert(membership && ["owner", "admin"].includes(membership.role), 403, "Only the workspace owner or an admin can change its logo.");';
 assert(handler.includes(roleGate));if(dropRoleGate)handler=handler.replace(roleGate,"");
 const brandStart=source.indexOf("const BRAND_FIELDS = ["),brandEnd=source.indexOf("// ── GET /me/compliance",brandStart);
 assert(start>=0&&end>start&&brandStart>0&&brandEnd>brandStart);
 const code=`
 import {HttpError,assert,json,pathSegments,readJsonLimited,respondError,throwRpc} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
 import {handleOptions} from ${JSON.stringify(new URL("../_shared/cors.ts",import.meta.url).href)};
 import {requestedWorkspace,workspaceDirectory} from ${JSON.stringify(new URL("../_shared/workspaces.ts",import.meta.url).href)};
 import {isSpaceType,SPACE_TYPES} from ${JSON.stringify(new URL("../_shared/spacetypes.ts",import.meta.url).href)};
 import {brandLogo} from ${JSON.stringify(new URL("./brand-logo.ts",import.meta.url).href)};
 export const state:any={options:{},rpc:[],meters:[],writes:0,deletions:0,object:null};
 export function reset(options:any={}){Object.assign(state,{options,rpc:[],meters:[],writes:0,deletions:0,object:null});}
 const getUser=async()=>{if(state.options.unauthorized)throw new HttpError(401,"Sign in required");return{id:${JSON.stringify(ACTOR)},email:"fixture.invalid"};};
 const adminClient=()=>({rpc:async(name:string,args:any)=>{state.rpc.push({name,args});if(name==="workspace_directory"){if(state.options.foreign)return{data:null,error:{message:"RP403: not a member"}};return{error:null,data:{active_org_id:${JSON.stringify(ORG)},workspaces:[{id:${JSON.stringify(ORG)},name:"Selected office",role:state.options.role??"owner"}]}};}
 if(name==="prepare_org_brand_logo")return{error:null,data:{org_id:args.p_org,actor_id:args.p_actor,object_key:"renders/"+args.p_org+"/brand/"+args.p_operation+".png",public_url:args.p_url,dispatch:true,replayed:false}};
 if(name==="publish_org_brand_logo")return{error:null,data:{org_id:args.p_org,business_logo_url:"https://cdn.fixture.invalid/renders/"+args.p_org+"/brand/"+args.p_operation+".png"}};
 if(name==="clear_org_brand_logo")return{error:null,data:{org_id:args.p_org,business_logo_url:null}};
 if(name==="merge_org_brand_fields")return{error:null,data:{id:args.p_org,name:"Selected office",handle:null,brand_kit:{...args.p_brand,business_logo_url:"https://cdn.fixture.invalid/existing.png"}}};
 throw Error("Unexpected RPC "+name);}});
 const durableRateLimit=async(key:string,max:number,seconds:number)=>{state.meters.push({key,max,seconds});return!state.options.limited;};
 const publishedBrandLogoUrl=(key:string)=>"https://cdn.fixture.invalid/"+key;
 const writeBrandLogo=async(_k:string,b:Uint8Array,type:string,sha256:string)=>{state.writes++;state.object={bytes:b.length,type,sha256,etag:'"synthetic"'};};
 const inspectBrandLogo=async()=>state.object;
 const preferredOrg=requestedWorkspace;const orgForUser=async(_user:string,org:string)=>org;
 const TOUR_BASE="https://tour.fixture.invalid";
 const handleDelete=async()=>{state.deletions++;return json({synthetic_account_deletion_invoked:true});};
 const handleGet=async()=>{throw Error("unexpected generic GET");};
 ${source.slice(brandStart,brandEnd)}
 ${handler}
 `;
 return await import("data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(code))));
}
function routeReq(method:string,body:unknown,org:string|null=ORG,path="brand/logo"){
 const headers:Record<string,string>={"content-type":"application/json"};if(org!==null)headers["X-Org-Id"]=org;
 return new Request("https://fixture.invalid/me/"+path,{method,headers,...(method!=="GET"?{body:JSON.stringify(body)}:{})});
}
Deno.test("actual /me logo route checks verified selected org and owner/admin before burst quota or objects",async()=>{
 const f=await routeFixture(),body={image_base64:base64(await png()),content_type:"image/png",expected_logo_url:null,client_operation_id:OP};
 for(const [options,org,status]of [[{},null,409],[{},"bad",400],[{unauthorized:true},ORG,401],[{foreign:true},ORG,403],[{role:"agent"},ORG,403],[{role:"marketing"},ORG,403]]as const){f.reset(options);assertEquals((await f.handler(routeReq("POST",body,org))).status,status);assertEquals(f.state.writes,0);assertEquals(f.state.meters,[]);}
 for(const role of ["owner","admin"]){f.reset({role});assertEquals((await f.handler(routeReq("POST",body))).status,200);assertEquals(f.state.writes,1);assertEquals(f.state.rpc[0],{name:"workspace_directory",args:{p_user:ACTOR,p_preferred_org:ORG}});assertEquals(f.state.rpc[1].args.p_actor,ACTOR);assertEquals(f.state.rpc[1].args.p_org,ORG);assertEquals(f.state.meters,[{key:`brandlogoburst:${ACTOR}`,max:30,seconds:300}]);}
 f.reset({limited:true});assertEquals((await f.handler(routeReq("POST",body))).status,429);assertEquals(f.state.writes,0);assertEquals(f.state.rpc.length,1);
});
Deno.test("actual /me logo clear never falls through to account deletion; ordinary text sends only explicit deltas",async()=>{
 const f=await routeFixture();f.reset();assertEquals((await f.handler(routeReq("POST",{expected_logo_url:null},ORG,"brand/logo/clear"))).status,200);assertEquals(f.state.deletions,0);assertEquals(f.state.writes,0);assertEquals(f.state.rpc.at(-1),{name:"clear_org_brand_logo",args:{p_actor:ACTOR,p_org:ORG,p_expected:null}});
 for(const path of ["brand/logo","brand/logo/clear","anything","brand/logo/anything"]){f.reset();const response=await f.handler(routeReq("DELETE",{},ORG,path));assert([404,405].includes(response.status));assertEquals(f.state.deletions,0);assertEquals(f.state.writes,0);assertEquals(f.state.rpc,[]);}
 f.reset();assertEquals((await f.handler(routeReq("DELETE",{},ORG,""))).status,200);assertEquals(f.state.deletions,1);
 f.reset();assertEquals((await f.handler(routeReq("GET",null))).status,405);assertEquals(f.state.rpc,[]);assertEquals(f.state.deletions,0);
 f.reset();const response=await f.handler(routeReq("PATCH",{title:" New title ",phone:null,org_name:" Office "},ORG,"brand"));assertEquals(response.status,200);assertEquals(f.state.rpc,[{name:"merge_org_brand_fields",args:{p_actor:ACTOR,p_org:ORG,p_brand:{title:"New title",phone:null},p_org_fields:{name:"Office"}}}]);assertEquals((await response.json()).brand_kit.business_logo_url,"https://cdn.fixture.invalid/existing.png");
 for(const body of [{business_logo_url:"https://evil.fixture.invalid/x"},{plan:"team"},{org_id:ACTOR,title:"wrong"}]){f.reset();assertEquals((await f.handler(routeReq("PATCH",body,ORG,"brand"))).status,400);assertEquals(f.state.rpc,[]);}
});
Deno.test("actual route role-gate mutation reaches forbidden dispatch and fails the named boundary assertion",async()=>{
 const f=await routeFixture(true);f.reset({role:"agent"});const response=await f.handler(routeReq("POST",{image_base64:base64(await png()),content_type:"image/png",expected_logo_url:null,client_operation_id:OP}));
 assertEquals(response.status,200);assertEquals(f.state.writes,1);
 await assertRejects(async()=>assertEquals(response.status,403,"owner/admin admission must refuse agent before dispatch"),Error,"owner/admin admission must refuse agent before dispatch");
});

Deno.test("actual immutable R2 logo dispatch signs overwrite guard and dispatches once without SDK retry or redirects",async()=>{
 const source=await Deno.readTextFile(new URL("../_shared/r2.ts",import.meta.url));
 const dispatchStart=source.indexOf("async function uploadDispatch("),dispatchEnd=source.indexOf("/** Immutable bounded Studio originals",dispatchStart);
 const logoStart=source.indexOf("export async function writeBrandLogo("),logoEnd=source.indexOf("export interface PresignArgs",logoStart);
 assert(dispatchStart>=0&&dispatchEnd>dispatchStart&&logoStart>0&&logoEnd>logoStart);
 const code=`import {HttpError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
 type AwsClient=any;export const state:any={signs:[],dispatches:[],status:200};
 const R2_BUCKET_RENDERS="fixture-renders",endpoint=()=>"https://objects.fixture.invalid";
 const client=()=>({sign:async(url:string,init:any)=>{state.signs.push({url,init});return new Request(url,{method:init.method,headers:init.headers,body:init.body});},fetch:()=>{throw Error("SDK retry path forbidden");}});
 const fetch=async(request:Request,options:any)=>{state.dispatches.push({request,options});return new Response(null,{status:state.status,headers:{"content-length":"3","content-type":"image/png","x-amz-meta-sha256":"a".repeat(64),etag:'"synthetic"'}});};
 ${source.slice(dispatchStart,dispatchEnd)}${source.slice(logoStart,logoEnd)}`;
 const f=await import("data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(code))));
 const key=`renders/${ORG}/brand/${OP}.png`,bytes=new Uint8Array([1,2,3]),hash="a".repeat(64);
 await f.writeBrandLogo(key,bytes,"image/png",hash);assertEquals(f.state.signs[0].init.aws,{allHeaders:true});assertEquals(f.state.signs[0].init.headers,{"content-type":"image/png","content-length":"3","if-none-match":"*","x-amz-meta-sha256":hash});assertEquals(f.state.dispatches.length,1);assertEquals(f.state.dispatches[0].options.redirect,"error");assert(f.state.dispatches[0].options.signal instanceof AbortSignal);
 f.state.status=412;await assertRejects(()=>f.writeBrandLogo(key,bytes,"image/png",hash),HttpError);assertEquals(f.state.dispatches.length,2);
 await assertRejects(()=>f.inspectBrandLogo(key),HttpError); // 412 is not a valid HEAD receipt.
 f.state.status=200;assertEquals(await f.inspectBrandLogo(key),{bytes:3,type:"image/png",sha256:hash,etag:'"synthetic"'});
 const count=f.state.dispatches.length;
 for(const [candidate,data,type]of [["renders/foreign/logo.png",bytes,"image/png"],[key,new Uint8Array(524289),"image/png"],[key,bytes,"image/svg+xml"]])await assertRejects(()=>f.writeBrandLogo(candidate,data,type,hash),HttpError);
 assertEquals(f.state.dispatches.length,count);
});
