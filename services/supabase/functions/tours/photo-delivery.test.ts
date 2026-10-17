import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {photoDelivery} from "./photo-delivery.ts";
import {HttpError} from "../_shared/http.ts";

const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002";
const key=`renders/${org}/${listing}/gallery-complete-version.jpg`,other=`renders/${org}/${listing}/gallery-unrelated.jpg`,slug="fixture-gallery";
const envelope=()=>({schema:1,slug,objects:{[key]:"renders"},stream_uid:null} as const);
function fixture(data:unknown=envelope(),error:{message?:string}|null=null){
 const calls:{name:string;args:Record<string,unknown>}[]=[];
 return {calls,db:{from(){throw Error("No per-table or unrelated public projection is allowed");},rpc(name:string,args:Record<string,unknown>){calls.push({name,args});return Promise.resolve({data,error});}}};
}
async function rejectStatus(fn:()=>Promise<unknown>,status:number){
 const error=await assertRejects(fn,HttpError);assertEquals(error.status,status);assert(!error.message.includes(key));
}
async function oracle(fn=photoDelivery){
 for(const bytes of[0,270000,2*1024*1024]){
  const f=fixture();assertEquals(await fn(f.db,slug,key,bytes),envelope());
  assertEquals(f.calls,[{name:"published_photo_delivery",args:{p_slug:slug,p_key:key,p_bytes:bytes}}]);
 }
}
Deno.test("original and bound saved-edit photo admission uses one exact current per-key RPC and a closed one-image envelope",()=>oracle());
Deno.test("only explicit SQL null delegates unsupported legacy lineage to complete authority",async()=>{
 const legacy=fixture(null);assertEquals(await photoDelivery(legacy.db,slug,key),null);assertEquals(legacy.calls.length,1);
 for(const data of[undefined,false,[],{},"null"]){const f=fixture(data);if(data===undefined){f.db.rpc=(_name,_args)=>Promise.resolve({data:undefined,error:null});}await rejectStatus(()=>photoDelivery(f.db,slug,key),503);}
});
Deno.test("authority refusals and transport errors fail closed without disclosing database messages or using generic fallback",async()=>{
 for(const status of[400,401,403,404,429])for(const data of[null,envelope()]){
  const f=fixture(data,{message:`RP${status}: private ${key}`});await rejectStatus(()=>photoDelivery(f.db,slug,key),status);assertEquals(f.calls.length,1);
 }
 for(const error of[{message:`private ${key}`},{}])await rejectStatus(()=>photoDelivery(fixture(null,error).db,slug,key),503);
 await rejectStatus(()=>photoDelivery({rpc(){throw Error(`private ${key}`);}},slug,key),503);
});
Deno.test("wrong slug/key/bucket, additional objects, stream identity and malformed response shapes cannot authorize bytes",async()=>{
 for(const data of[
  {...envelope(),slug:"other-property"},{...envelope(),schema:2},{...envelope(),stream_uid:"f".repeat(32)},
  {...envelope(),objects:{[other]:"renders"}},{...envelope(),objects:{[key]:"uploads"}},
  {...envelope(),objects:{[key]:"renders",[other]:"renders"}},{...envelope(),objects:[]},
  {...envelope(),objects:null},{...envelope(),private_source:key},
 ])await rejectStatus(()=>photoDelivery(fixture(data).db,slug,key),503);
});
Deno.test("malformed slug/key and out-of-bound byte requests are refused before any database call",async()=>{
 for(const [s,k,b]of[["",key,0],["bad/slug",key,0],["a".repeat(65),key,0],[slug,null,0],[slug,"",0],[slug,"a".repeat(501),0],
  ...[-1,2*1024*1024+1,NaN,Infinity,0.5].map(bytes=>[slug,key,bytes])]){
  const f=fixture();await rejectStatus(()=>photoDelivery(f.db,s as string,k,b as number),400);assertEquals(f.calls,[]);
 }
});
Deno.test("compiled error, fallback and exact-response omission controls fail the same boundary oracles",async()=>{
 const original=await Deno.readTextFile(new URL("./photo-delivery.ts",import.meta.url));
 const cases:[string,string,(fn:typeof photoDelivery)=>Promise<void>][]=[
  ["if(error){","if(false){",async fn=>{await rejectStatus(()=>fn(fixture(envelope(),{message:"RP404: revoked"}).db,slug,key),404);}],
  ["if(data===null)return null;","if(data==null)return null;",async fn=>{await rejectStatus(()=>fn({rpc:()=>Promise.resolve({data:undefined,error:null})},slug,key),503);}],
  ["value.slug===slug","true",async fn=>{await rejectStatus(()=>fn(fixture({...envelope(),slug:"other-property"}).db,slug,key),503);}],
  ["Object.keys(objects).length===1","true",async fn=>{await rejectStatus(()=>fn(fixture({...envelope(),objects:{[key]:"renders",[other]:"renders"}}).db,slug,key),503);}],
  ['(objects as Record<string,unknown>)[key]==="renders"',"true",async fn=>{await rejectStatus(()=>fn(fixture({...envelope(),objects:{[key]:"uploads"}}).db,slug,key),503);}],
 ];
 for(const [from,to,check]of cases){
  assertEquals(original.split(from).length,2);
  const source=original.replace(from,to).replace(/from "(\.\.?\/[^\"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,new URL("./photo-delivery.ts",import.meta.url)).href)}`);
  const fn=(await import(`data:application/typescript;base64,${btoa(source)}`)).photoDelivery;
  await oracle(fn);await assertRejects(()=>check(fn));await check(photoDelivery);
 }
});
