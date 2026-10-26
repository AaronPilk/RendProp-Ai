import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { publicationHash, verifyPublicationBody, type PublicationObject } from "./photo-publication-bytes.ts";
import type { PublicationIO } from "./photo-publication.ts";
export const publicationID=(n:number)=>`f0201020-0000-4000-8000-${n.toString(16).padStart(12,"0")}`;
export async function publicationFixture(){
  const actor=publicationID(1),org=publicationID(2),listing=publicationID(3),library=publicationID(4),asset=publicationID(5),copy=publicationID(6),evidence=publicationID(7),check=publicationID(8),original=publicationID(9),pub=publicationID(10),operation=publicationID(11),copyOperation=publicationID(12);
  const input=new Uint8Array([255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
  const output=input.slice();output[output.length-3]=2;
  const inputSHA=await publicationHash(input),outputSHA=await publicationHash(output);
  const inputKey=`ai-router/${org}/photo-evidence/${actor}/${evidence}/input.jpg`,outputKey=`ai-router/${org}/photo-evidence/${actor}/${evidence}/candidate.jpg`,targetKey=`renders/${org}/${listing}/gallery-${asset}-complete-${operation}.jpg`,copyKey=`renders/${org}/${listing}/original-${copy}.jpg`;
  const stored=new Map<string,{body:Uint8Array<ArrayBuffer>;etag:string}>([[inputKey,{body:input,etag:'"input"'}],[outputKey,{body:output,etag:'"output"'}],[targetKey,{body:output,etag:'"target"'}]]);
  const target={asset_id:asset,key:targetKey,bytes:output.length,mime:"image/jpeg",sha256:outputSHA,etag:'"target"',operation_id:operation};
  const source_input={key:inputKey,bytes:input.length,mime:"image/jpeg",sha256:inputSHA,etag:'"input"'},source_output={key:outputKey,bytes:output.length,mime:"image/jpeg",sha256:outputSHA,etag:'"output"'};
  const root={id:original,org_id:org,listing_id:null,kind:"declutter",disclosure:"Digitally decluttered; compare the submitted source.",qc:{task:"judge.photo_fixed_features",medium:"photo",policy:"photo-fixed-features-v1",publishable:true,action:"accept",purpose:"prospective",check_id:check,evidence_id:evidence,prepared_sha256:inputSHA,output_sha256:outputSHA},qc_checked_at:"2026-10-20T18:29:10Z"};
  const e={id:evidence,actor_id:actor,org_id:org,library_org_id:library,listing_id:null,state:"accept",purpose:"prospective",provenance_id:original,request_key:"C082AA20-63A9-4213-9F13-004D315A4365",request_sha256:"c".repeat(64)};
  const q={id:check,evidence_id:evidence,automatic:true,state:"accept"};
  const state={ordinary:false,resolveError:null as string|null,finishError:null as string|null,phase:null as string|null,claims:0,writes:0,unknownWrite:false,missingCopy:false,calls:[] as {name:string;args:any}[],reads:[] as string[],admissions:[] as number[],claim:"",target,e,q,root};
  const history=structuredClone({e,q,root,ledger:[{id:publicationID(20),total_cents:40.412}]});
  const publication=()=>state.phase===null?null:{id:pub,photo_publication:{schema:1,phase:state.phase,source:{evidence_id:evidence,provenance_id:original,automatic_check_id:check,actor_id:actor,org_id:org,library_org_id:library,listing_id:null,request_key:e.request_key,request_sha256:e.request_sha256},target:{listing_id:listing,org_id:org,library_org_id:library,output_asset_id:asset,source_copy_asset_id:copy},input:source_input,output:source_output}};
  const base=()=>({actor_id:actor,org_id:org,library_org_id:library,listing_id:listing,target:structuredClone(target),publication:publication()});
  const resolved=()=>({...base(),evidence:structuredClone(e),check:structuredClone(q),provenance:structuredClone(root),source_input:structuredClone(source_input),source_output:structuredClone(source_output)});
  const copy_asset=()=>({asset_id:copy,key:copyKey,bytes:input.length,mime:"image/jpeg",sha256:inputSHA,etag:state.phase==="prepared"?'"copy"':null});
  const client={rpc:async(name:string,args:any)=>{
    state.calls.push({name,args:structuredClone(args)});
    if(name==="hosting_retention_state")return{data:{org_id:library,policy:"preserved",protected:false,retention_ends_at:null,hosting_available:true},error:null};
    assertEquals(args.p_actor,actor);assertEquals(args.p_org,org);assertEquals(args.p_library,library);assertEquals(args.p_listing===null||args.p_listing===listing,true);
    if(name==="photo_publication_target")return{data:base(),error:null};
    if(name==="photo_publication_resolve")return state.resolveError?{data:null,error:{message:state.resolveError}}:{data:state.ordinary?null:resolved(),error:null};
    if(name==="photo_publication_reserve"){
      assertEquals(args.p_evidence,evidence);assertEquals(args.p_verified_input.sha256,inputSHA);assertEquals(args.p_verified_output.sha256,outputSHA);assertEquals(args.p_verified_target.sha256,outputSHA);
      const dispatch=state.phase===null;if(dispatch){state.phase="preparing";state.claim=args.p_claim;state.claims++;}
      return{data:{...resolved(),dispatch,copy_asset:copy_asset(),copy_operation:{id:copyOperation,asset_id:copy,bucket:"renders",object_key:copyKey,state:state.phase==="prepared"?"retained":"dispatching",claim:state.claim,dispatch}},error:null};
    }
    if(name==="photo_publication_finish"){
      if(state.finishError)return{data:null,error:{message:state.finishError}};
      assertEquals(args.p_publication,pub);assertEquals(args.p_verified_source.sha256,inputSHA);assertEquals(args.p_verified_source.etag,'"copy"');assertEquals(args.p_verified_target.sha256,outputSHA);state.phase="prepared";
      return{data:{...resolved(),dispatch:false,copy_asset:copy_asset()},error:null};
    }
    throw new Error("Unexpected publication RPC "+name);
  }};
  const io:PublicationIO={
    read:async(o:PublicationObject,signal)=>{state.reads.push(o.key);const row=stored.get(o.key);const response=row?new Response(row.body,{headers:{"content-length":String(row.body.length),"content-type":"image/jpeg",etag:row.etag}}):new Response(null,{status:404});return await verifyPublicationBody(response,o,signal);},
    head:async(o)=>{const row=state.missingCopy?undefined:stored.get(o.key);return{exists:!!row,bytes:row?.body.length??null,mime:row?"image/jpeg":null,etag:row?.etag??null};},
    write:async(key,body,mime,sha)=>{assertEquals(state.claims,1);assertEquals(state.phase,"preparing");assertEquals(key,copyKey);assertEquals(body,input);assertEquals(mime,"image/jpeg");assertEquals(sha,inputSHA);state.writes++;if(!stored.has(key))stored.set(key,{body:body.slice(),etag:'"copy"'});if(state.unknownWrite)throw new TypeError("Synthetic lost copy reply");},
    admit:async(_db,o,bytes,a)=>{assertEquals(o,org);assertEquals(a,actor);state.admissions.push(bytes);},
  };
  return{actor,org,listing,library,asset,copy,evidence,check,original,pub,operation,copyOperation,input,inputSHA,output,outputSHA,inputKey,outputKey,targetKey,copyKey,stored,source_input,source_output,target,state,history,client,io,scope:{orgId:org,libraryOrgId:library,listingId:listing},resolved,base};
}
