import {assert,assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {photoQualityResponse,throwPhotoQualityState,type PhotoQualityEnvelope} from "./photo-qc-store.ts";
import {HttpError} from "../_shared/http.ts";
const id=(n:number)=>`ea100606-0000-4000-8000-${String(n).padStart(12,"0")}`,actor=id(1),org=id(2),listing=id(3);
function fixture(){return{evidence:{id:id(4),actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:"closed-review-fixture",request_sha256:"a".repeat(64),policy:"photo-fixed-features-v1",state:"hold",failure:{phase:"generation",facts:{provider_cost_incurred:"possible",retained_output:false}}},check:{id:id(5),evidence_id:id(4),policy:"photo-fixed-features-v1",state:"hold",judge_started_at:null,finished_at:"2026-10-15T06:00:00.000Z"},can_continue:false}as unknown as PhotoQualityEnvelope;}
Deno.test("only a completed immutable HOLD releases a consumer operation even if supplier cost remains possible",()=>{
 for(const cost of[true,"possible",false]){const row=fixture();row.evidence.failure!.facts!.provider_cost_incurred=cost;const before=structuredClone(row);
  const error=assertThrows(()=>throwPhotoQualityState(row,org),HttpError);
  assertEquals(error.status,422);assertEquals(error.code,"photo_quality_closed");assertEquals(error.details?.operation_closed,true);assertEquals(error.details?.retry_existing_job,false);assertEquals(error.details?.provider_cost_incurred,cost);assertEquals(error.details?.check_id,id(5));assertEquals(error.details?.evidence_id,id(4));assertEquals(error.details?.image_b64,undefined);assertEquals(error.details?.asset_key,undefined);assert(error.message.includes("allowance"));assertEquals(row,before,"Projection never changes the old receipt or cost");
 }
});
Deno.test("active checking, inconsistent evidence and missing/invalid finish never close a saved operation",()=>{
 for(const patch of[
  {check:{state:"checking",judge_started_at:"2026-10-15T05:59:00Z"}},
  {evidence:{state:"checking"}},
  ...[null,undefined,"","not-a-timestamp",123].map(finished_at=>({check:{finished_at}})),
  {check:{state:"pending"}},{check:{state:"preparing"}},
 ]){const row=fixture();Object.assign(row.check,patch.check??{});Object.assign(row.evidence,(patch as {evidence?:Record<string,unknown>}).evidence??{});
  const error=assertThrows(()=>throwPhotoQualityState(row,org),HttpError);assertEquals(error.status,409);assertEquals(error.details?.operation_closed,undefined);assertEquals(error.details?.retry_existing_job,true);
 }
});
Deno.test("fresh selected-library authority is checked before a closed response, and no storage/promotion writes occur",async()=>{
 let current=true,calls=0;const row=fixture();const admin={rpc:async()=>{calls++;return current?{data:{actor_id:actor,listing_id:listing,org_id:org,library_org_id:org,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true},error:null}:{data:null,error:{message:"RP404: Removed"}};}};
 const error=await assertRejects(()=>photoQualityResponse(admin,row,actor,org),HttpError);assertEquals(error.code,"photo_quality_closed");assertEquals(calls,1);
 current=false;const revoked=await assertRejects(()=>photoQualityResponse(admin,row,actor,org),HttpError);assertEquals(revoked.status,404);assertEquals(revoked.code,"not_found");assertEquals(calls,2);
});
