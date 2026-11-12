import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {recordDirectPropertyVideoSource} from "./property-source-provenance.ts";
const args={actor:"actor",org:"org",key:"operation-key",request:"accepted-request",source:{listing:"listing",asset:"source",photoProvenance:null,sha256:"a".repeat(64),qcHash:"b".repeat(32)},label:"Kitchen",style:"side_glide",promptSummary:null};
const reply={bound:true,request_id:args.request,provenance_id:"fa850000-0000-4000-8000-000000000001",disclosure:"Stored SQL disclosure"};
Deno.test("direct provenance sends exact paid/source scope once and returns SQL disclosure",async()=>{
 const calls:any[]=[];const result=await recordDirectPropertyVideoSource(args,async(name,input)=>{calls.push({name,input});return{data:reply,error:null};});
 assertEquals(calls,[{name:"record_direct_property_video_source",input:{p_actor:"actor",p_org:"org",p_key:"operation-key",p_listing:"listing",p_asset:"source",p_photo_provenance:null,p_request:"accepted-request",p_sha256:args.source.sha256,p_qc_hash:args.source.qcHash,p_label:"Kitchen",p_style:"side_glide",p_prompt_summary:null}}]);
 assertEquals(result,{provenance:{id:reply.provenance_id,recorded:true,disclosure:reply.disclosure},sourceBound:true});
});
Deno.test("direct provenance rejects malformed/cross-request receipts without raw details or fallback RPC",async()=>{
 for(const data of[null,[],{}, {...reply,bound:"true"},{...reply,request_id:"other"},{...reply,provenance_id:"bad"},{...reply,disclosure:""},{...reply,disclosure:"x".repeat(2001)}]){
  let count=0;const result=await recordDirectPropertyVideoSource(args,async()=>{count++;return{data,error:null};});
  assertEquals(count,1);assertEquals(result.sourceBound,false);assertEquals(result.provenance.id,null);assertEquals(result.provenance.recorded,false);assertEquals(result.provenance.reason,"source_audit_unavailable");
 }
 for(const throwing of[false,true]){let count=0;const result=await recordDirectPropertyVideoSource(args,async()=>{count++;if(throwing)throw Error("private DB detail");return{data:reply,error:{message:"private DB detail"}};});assertEquals(count,1);assert(!JSON.stringify(result).includes("private DB detail"));assertEquals(result.sourceBound,false);}
});
Deno.test("compiled omitted request echo check fails the same closed response oracle",async()=>{
 async function oracle(fn:typeof recordDirectPropertyVideoSource){const r=await fn(args,async()=>({data:{...reply,request_id:"other-request"},error:null}));assertEquals(r.sourceBound,false);assertEquals(r.provenance.id,null);}
 await oracle(recordDirectPropertyVideoSource);
 const text=await Deno.readTextFile(new URL("./property-source-provenance.ts",import.meta.url));const needle="row.request_id === args.request &&";assertEquals(text.split(needle).length,2);
 const mutant=text.replace(needle,"").replace('"../_shared/provenance.ts"',JSON.stringify(new URL("../_shared/provenance.ts",import.meta.url).href));
 const url="data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(mutant)));const broken=await import(url);
 let caught=false;try{await oracle(broken.recordDirectPropertyVideoSource);}catch(e){if(e instanceof Error&&e.message.includes("Values are not equal"))caught=true;else throw e;}assert(caught,"request identity omission must fail actual oracle");
});
