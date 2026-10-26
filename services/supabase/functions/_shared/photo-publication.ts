// Explicit publication of an already accepted photo. No generator, judge,
// funding admission, replacement request key or historical mutation belongs here.
import { assert, HttpError } from "./http.ts";
import { admitMediaRead } from "./media-delivery-admission.ts";
import { assertHostingAvailable } from "./hosting-retention.ts";
import { presignGet } from "./providers/common.ts";
import { R2_BUCKET_RENDERS, headObject, writePhotoPublicationSource } from "./r2.ts";
import { PHOTO_OUTPUT_MAX_BYTES } from "./photo-output-policy.ts";
import { verifyPublicationBody, type PublicationObject, type PublicationProof } from "./photo-publication-bytes.ts";

type Row = Record<string, any>;
export type PublicationClient = { rpc(name:string,args:Row):PromiseLike<{data:any;error:{message?:string}|null}> };
export type PublicationScope = { orgId:string; libraryOrgId:string; listingId:string|null };
export type PreparedPhotoPublication = { id:string; sourceProvenanceID:string; listingID:string; outputAssetID:string; sourceAssetID:string; disclosure:string; kind:string };
export type PublicationIO = {
  read(object:PublicationObject,signal:AbortSignal):Promise<{proof:PublicationProof;body:Uint8Array<ArrayBuffer>}>;
  head(object:PublicationObject,signal:AbortSignal):Promise<{exists:boolean;bytes:number|null;mime:string|null;etag:string|null}>;
  write(key:string,bytes:Uint8Array<ArrayBuffer>,mime:string,sha256:string,signal:AbortSignal):Promise<void>;
  admit(admin:PublicationClient,org:string,bytes:number,actor:string):Promise<void>;
};
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA=/^[a-f0-9]{64}$/;
const MIME=["image/jpeg","image/png","image/webp"];
const object=(v:unknown):v is Row=>!!v&&typeof v==="object"&&!Array.isArray(v);
const fail=()=>new HttpError(503,"The saved photo publication could not be verified. Its edit and listing selection are kept.");
const etag=(v:unknown):v is string=>typeof v==="string"&&v.length>0&&v.length<=256&&!/[\u0000-\u001f\u007f]/.test(v);
function safeKey(v:unknown):v is string{return typeof v==="string"&&v.length>0&&v.length<=1024&&!/[\\%?#\u0000-\u001f]/.test(v)&&!v.split("/").some(x=>!x||x==="."||x==="..");}
function file(v:unknown,expectedPrefix:string):PublicationObject{
  if(!object(v)||!safeKey(v.key)||!v.key.startsWith(expectedPrefix)||!Number.isSafeInteger(v.bytes)||v.bytes<1||v.bytes>PHOTO_OUTPUT_MAX_BYTES||!MIME.includes(v.mime)||(!etag(v.etag)||v.etag.length>200)||typeof v.sha256!=="string"||!SHA.test(v.sha256))throw fail();
  return{key:v.key,bytes:v.bytes,mime:v.mime,etag:v.etag,sha256:v.sha256};
}
function target(v:unknown,scope:{actor:string;org:string;library:string;listing:string|null}):Row{
  if(!object(v)||v.actor_id!==scope.actor||v.org_id!==scope.org||v.library_org_id!==scope.library||!UUID.test(v.listing_id)||scope.listing!==null&&v.listing_id!==scope.listing||!object(v.target))throw fail();
  const t=v.target,prefix=`renders/${scope.org}/${v.listing_id}/`;
  if(!UUID.test(t.asset_id)||!safeKey(t.key)||!t.key.startsWith(prefix)||t.key.slice(prefix.length).includes("/")||!Number.isSafeInteger(t.bytes)||t.bytes<1||t.bytes>134217728||!MIME.includes(t.mime)||!etag(t.etag)||!UUID.test(t.operation_id)||!(t.sha256===null||typeof t.sha256==="string"&&SHA.test(t.sha256)))throw fail();
  return v;
}
function source(v:unknown,scope:{actor:string;org:string;library:string;listing:string},expectedProvenance?:string):Row{
  const r=target(v,scope),e=r.evidence,q=r.check,m=r.provenance;
  if(!object(e)||!object(q)||!object(m)||!UUID.test(e.id)||!UUID.test(q.id)||q.evidence_id!==e.id||q.automatic!==true||e.actor_id!==scope.actor||e.org_id!==scope.org||e.library_org_id!==scope.library||e.listing_id!==null||e.state!=="accept"||e.purpose!=="prospective"||q.state!=="accept"||!UUID.test(e.provenance_id)||m.id!==e.provenance_id||expectedProvenance!==undefined&&m.id!==expectedProvenance||m.org_id!==scope.org||m.listing_id!==null||!object(m.qc)||m.qc.publishable!==true||m.qc.action!=="accept"||m.qc.evidence_id!==e.id||m.qc.check_id!==q.id||typeof m.disclosure!=="string"||!m.disclosure.trim())throw fail();
  const prefix=`ai-router/${scope.org}/photo-evidence/${scope.actor}/${e.id}/`;
  const input=file(r.source_input,prefix),output=file(r.source_output,prefix);
  if(!new RegExp(`^${prefix}input\\.(jpg|png|webp)$`).test(input.key)||!new RegExp(`^${prefix}candidate\\.(jpg|png|webp)$`).test(output.key)||m.qc.prepared_sha256!==input.sha256||m.qc.output_sha256!==output.sha256)throw fail();
  return r;
}
async function rpc(admin:PublicationClient,name:string,args:Row,signal:AbortSignal):Promise<any>{
  signal.throwIfAborted();
  let result;try{let query=admin.rpc(name,args);if(typeof (query as any)?.abortSignal==="function")query=(query as any).abortSignal(signal);result=await query;}catch{throw fail();}
  signal.throwIfAborted();
  if(result.error){const m=/^RP(400|403|404|409|429): (.{1,240})$/.exec(result.error.message??"");throw new HttpError(m?Number(m[1]):503,m?m[2]:"This saved publication is unavailable. Its edit and listing selection are kept.");}
  return result.data;
}
const defaults:PublicationIO={
  read:async(o,signal)=>{
    const response=await fetch(await presignGet(R2_BUCKET_RENDERS,o.key,60),{method:"GET",credentials:"omit",redirect:"error",headers:{"If-Match":o.etag},signal});
    return await verifyPublicationBody(response,o,signal);
  },
  head:async(o,signal)=>{const h=await headObject(R2_BUCKET_RENDERS,o.key,signal);return{exists:h.exists,bytes:h.bytes,mime:h.contentType?.split(";")[0].trim().toLowerCase()??null,etag:h.etag};},
  write:writePhotoPublicationSource,
  admit:(admin,org,bytes,actor)=>admitMediaRead(admin,org,bytes,false,actor),
};

/** Both a NULL-disclosure PATCH and a selecting-asset retry use this admission.
 * A completed upload alone never certifies that its disclosure was prepared. */
export async function ensureAcceptedPhotoPublication(
  admin:PublicationClient,scope:PublicationScope,actor:string,asset:string,
  options:{provenanceID?:string;reviewed?:boolean;expected?:{sha256:string;bytes:number};signal?:AbortSignal}={},
  io:PublicationIO=defaults,
):Promise<PreparedPhotoPublication|null>{
  assert(UUID.test(actor)&&UUID.test(scope.orgId)&&UUID.test(scope.libraryOrgId)&&(scope.listingId===null||UUID.test(scope.listingId))&&UUID.test(asset)&&(options.provenanceID===undefined||UUID.test(options.provenanceID)),400,"Choose the exact saved photo and current library.");
  const signal=AbortSignal.any([...(options.signal?[options.signal]:[]),AbortSignal.timeout(90_000)]);
  const identity={actor,org:scope.orgId,library:scope.libraryOrgId,listing:scope.listingId};
  let args:Row={p_actor:actor,p_org:scope.orgId,p_library:scope.libraryOrgId,p_listing:scope.listingId,p_asset:asset};
  const initial=target(await rpc(admin,"photo_publication_target",args,signal),identity);
  assert(initial.target.asset_id===asset,503,"The saved upload returned another photo.");
  const full={...identity,listing:initial.listing_id as string};args={...args,p_listing:full.listing};
  if(options.expected)assert(initial.target.bytes===options.expected.bytes&&(initial.target.sha256===null||initial.target.sha256===options.expected.sha256),409,"The chosen photo changed before selection.");
  // No accepted prospective output can exceed the existing generator's bound.
  // Preserve larger ordinary upload behavior; explicit/marked AI never skips.
  if(initial.target.bytes>PHOTO_OUTPUT_MAX_BYTES){assert(!options.provenanceID&&initial.publication===null,409,"This saved edit exceeds its publication receipt.");return null;}
  await assertHostingAvailable(admin,scope.libraryOrgId);
  await io.admit(admin,scope.orgId,initial.target.bytes,actor);
  const actualTarget=(await io.read(initial.target,signal)).proof;
  if(options.expected)assert(actualTarget.sha256===options.expected.sha256&&actualTarget.bytes===options.expected.bytes,409,"The chosen photo bytes changed before selection.");
  let resolved=await rpc(admin,"photo_publication_resolve",{...args,p_provenance:options.provenanceID??null,p_verified_target:actualTarget},signal);
  if(resolved===null){assert(options.provenanceID===undefined&&initial.publication===null,404,"The saved photo disclosure is unavailable.");return null;}
  resolved=source(resolved,full,options.provenanceID);
  assert(resolved.target.asset_id===asset&&resolved.source_output.sha256===actualTarget.sha256&&resolved.source_output.bytes===actualTarget.bytes&&resolved.source_output.mime===actualTarget.mime,409,"This uploaded photo is not the exact accepted result.");
  assert(options.reviewed!==false,409,"Compare the accepted edit with its retained source before choosing it.");
  await io.admit(admin,scope.orgId,resolved.source_input.bytes+resolved.source_output.bytes,actor);
  const input=await io.read(resolved.source_input,signal),output=(await io.read(resolved.source_output,signal)).proof;
  assert(output.sha256===actualTarget.sha256&&output.bytes===actualTarget.bytes&&output.mime===actualTarget.mime,409,"The retained result changed. No substitute was published.");
  const claim=crypto.randomUUID();
  const reserved=source(await rpc(admin,"photo_publication_reserve",{...args,p_evidence:resolved.evidence.id,p_verified_input:input.proof,p_verified_output:output,p_verified_target:actualTarget,p_claim:claim},signal),full,options.provenanceID);
  if(reserved.evidence.id!==resolved.evidence.id||reserved.check.id!==resolved.check.id||JSON.stringify(reserved.source_input)!==JSON.stringify(resolved.source_input)||JSON.stringify(reserved.source_output)!==JSON.stringify(resolved.source_output)||!object(reserved.publication)||!UUID.test(reserved.publication.id)||!object(reserved.copy_asset)||!UUID.test(reserved.copy_asset.asset_id)||!object(reserved.copy_operation)||typeof reserved.dispatch!=="boolean")throw fail();
  const copy=reserved.copy_asset,prefix=`renders/${scope.orgId}/${full.listing}/original-${copy.asset_id}.`;
  if(!safeKey(copy.key)||!copy.key.startsWith(prefix)||!['jpg','png','webp'].includes(copy.key.slice(prefix.length))||copy.bytes!==input.proof.bytes||copy.sha256!==input.proof.sha256||copy.mime!==input.proof.mime||reserved.copy_operation.asset_id!==copy.asset_id||reserved.copy_operation.object_key!==copy.key||reserved.copy_operation.bucket!=="renders")throw fail();
  if(reserved.dispatch){
    assert(reserved.copy_operation.state==="dispatching"&&reserved.copy_operation.claim===claim,503,"The submitted-source copy has no owned dispatch claim.");
    await io.write(copy.key,input.body,input.proof.mime,input.proof.sha256,signal);
  }
  await io.admit(admin,scope.orgId,copy.bytes,actor);
  const copyObject:PublicationObject={key:copy.key,bytes:copy.bytes,mime:copy.mime,sha256:copy.sha256,etag:copy.etag??""};
  const head=await io.head(copyObject,signal);
  assert(head.exists&&head.bytes===input.proof.bytes&&head.mime===input.proof.mime&&etag(head.etag)&&(copy.etag===null||copy.etag===head.etag),409,"The saved submitted-source copy is unconfirmed. Check this same publication.");
  const copied=await io.read({...copyObject,etag:head.etag!},signal);
  assert(copied.proof.sha256===input.proof.sha256&&copied.proof.bytes===input.proof.bytes&&copied.proof.mime===input.proof.mime,409,"The submitted-source copy is not exact.");
  const final=source(await rpc(admin,"photo_publication_finish",{p_actor:actor,p_org:scope.orgId,p_library:scope.libraryOrgId,p_listing:full.listing,p_publication:reserved.publication.id,p_verified_source:copied.proof,p_verified_target:actualTarget},signal),full,options.provenanceID);
  const publication=final.publication?.photo_publication;
  if(final.publication?.id!==reserved.publication.id||publication?.phase!=="prepared"||final.target.asset_id!==asset||final.copy_asset?.asset_id!==copy.asset_id)throw fail();
  return{id:final.publication.id,sourceProvenanceID:final.provenance.id,listingID:full.listing,outputAssetID:asset,sourceAssetID:copy.asset_id,disclosure:final.provenance.disclosure,kind:final.provenance.kind};
}
