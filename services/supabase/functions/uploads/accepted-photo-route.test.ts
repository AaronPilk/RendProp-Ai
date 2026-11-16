import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fixture, object, PARTS } from "../../../../tools/audit/upload_route_fixture.ts";

// Exercise the actual handler, including durable settlement and its early
// uploaded replay. The canonical physical-body success path is tested in
// accepted-photo.test.ts; this route must never swallow its refusal.
Deno.test("actual upload completion and settled replay both require accepted-photo preparation",async()=>{
  await fixture(async f=>{
    const actor="a1111111-1111-4111-8111-111111111111",org="b2222222-2222-4222-8222-222222222222";
    const listing="c3333333-3333-4333-8333-333333333333",id="d4444444-4444-4444-8444-444444444444";
    const key=`renders/${org}/${listing}/gallery-${id}.jpg`;
    Object.assign(f.asset!,{id,listing_id:listing,storage_key:key,kind:"photo",bucket:"renders",content_type:"image/jpeg",sha256:"a".repeat(64)});
    f.objects.clear();f.objects.set("_staging/"+key,object("AAAA",4,"image/jpeg"));
    const original=globalThis.fetch;let prefilters=0,preparations=0;
    globalThis.fetch=async(input,init)=>{
      const request=new Request(input,init),url=new URL(request.url);
      if(url.pathname==="/rest/v1/photo_edit_evidence"){
        prefilters++;assertEquals(url.searchParams.get("limit"),"1");return Response.json([{id}]);
      }
      if(url.pathname==="/rest/v1/upload_reservations")return Response.json({asset_id:id,actor_id:actor,org_id:org,listing_id:listing,
        state:"completed",spec:{key_role:"gallery",listing_id:listing,kind:"photo",bucket:"renders",bytes:4}});
      if(url.pathname==="/rest/v1/rpc/photo_publication_target"){
        preparations++;return Response.json({message:"RP409: Retained edit is withdrawn"},{status:400});
      }
      return await original(input,init);
    };
    const first=await f.request("complete",{sha256:"a".repeat(64)});
    assertEquals(first.status,409);assertEquals(f.asset!.uploaded,true);assertEquals(f.copies.length,1);
    assertEquals(prefilters,1);assertEquals(preparations,1);
    const before=structuredClone(f.asset);
    const replay=await f.request("complete",{sha256:"b".repeat(64)});
    assertEquals(replay.status,409);assertEquals(prefilters,2);assertEquals(preparations,2);
    assertEquals(f.asset,before);assertEquals(f.copies.length,1);assertEquals(f.deletes,[]);
  });
});

for(const race of ["multipart manifest", "cancellation"])
Deno.test(`concurrent completed ${race} winner still requires accepted-photo preparation`,async()=>{
  await fixture(async f=>{
    const actor="a1111111-1111-4111-8111-111111111111",org="b2222222-2222-4222-8222-222222222222";
    const listing="c3333333-3333-4333-8333-333333333333",id="d4444444-4444-4444-8444-444444444444";
    const key=`renders/${org}/${listing}/gallery-${id}.jpg`;
    Object.assign(f.asset!,{id,listing_id:listing,storage_key:key,kind:"photo",bucket:"renders",content_type:"image/jpeg",sha256:"a".repeat(64)});
    f.objects.clear();
    if(race==="multipart manifest"){
      f.multipart();f.beforePatch=async patch=>{if(patch.completion_parts)f.asset!.uploaded=true;};
    }else{
      f.objects.set("_staging/"+key,object("BAD",3,"image/jpeg"));
      f.afterHead=async()=>{f.asset!.uploaded=true;};
    }
    const original=globalThis.fetch;let preparations=0;
    globalThis.fetch=async(input,init)=>{
      const request=new Request(input,init),url=new URL(request.url);
      if(url.pathname==="/rest/v1/photo_edit_evidence")return Response.json([{id}]);
      if(url.pathname==="/rest/v1/upload_reservations")return Response.json({asset_id:id,actor_id:actor,org_id:org,listing_id:listing,
        state:"completed",spec:{key_role:"gallery",listing_id:listing,kind:"photo",bucket:"renders",bytes:4}});
      if(url.pathname==="/rest/v1/rpc/photo_publication_target"){
        preparations++;return Response.json({message:"RP409: Retained edit is withdrawn"},{status:400});
      }
      return await original(input,init);
    };
    const response=await f.request("complete",race==="multipart manifest"?{parts:PARTS}:{});
    assertEquals(response.status,409,await response.clone().text());assertEquals(preparations,1);
    assertEquals(f.asset!.uploaded,true);assertEquals(f.copies,[]);assertEquals(f.deletes,[]);
  });
});
