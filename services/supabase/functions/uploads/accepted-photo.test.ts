import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { publicationFixture, publicationID } from "../_shared/photo-publication.fixture.ts";
import { prepareAcceptedGalleryUpload } from "./accepted-photo.ts";

async function fixture() {
  const f = await publicationFixture({ bound: true });
  const asset = { id:f.asset, listing_id:f.listing, storage_key:f.targetKey, kind:"photo", bucket:"renders",
    uploaded:true, upload_aborted:false, transport_version:2, sha256:f.outputSHA, bytes:f.output.length, content_type:"image/jpeg" };
  const reservation = { asset_id:f.asset, actor_id:f.actor, org_id:f.org, listing_id:f.listing, state:"completed",
    spec:{key_role:"gallery",listing_id:f.listing,kind:"photo",bucket:"renders",bytes:f.output.length} };
  const scope = { actor_id:f.actor, org_id:f.org, library_org_id:f.library, listing_id:f.listing,
    billing_org_id:f.org, team_org_id:null, library_owner_user_id:f.actor, listing_owner_user_id:f.actor,
    role:"owner", access_mode:"own", can_read:true, can_write:true, can_manage_subscription:true };
  const control = { candidate:true, lookupError:false, ordinary:false, queries:[] as any[] };
  const admin = {
    rpc:async(name:string,args:any) => name === "listing_library_scope"
      ? { data:structuredClone(scope), error:null } : await f.client.rpc(name,args),
    from:(table:string) => {
      const query:any={table,filters:[]};control.queries.push(query);
      const chain:any={select:(v:any)=>{query.select=v;return chain;},
        contains:(key:any,value:any)=>{query.filters.push([key,value]);return chain;},
        eq:(key:any,value:any)=>{query.filters.push([key,value]);return chain;},
        limit:(v:any)=>{query.limit=v;return chain;},maybeSingle:()=>chain,
        abortSignal:async(signal:AbortSignal)=>{
          signal.throwIfAborted();
          if(table==="photo_edit_evidence"){
            assertEquals(query.select,"id");assertEquals(query.limit,1);
            assertEquals(query.filters,[["output->>sha256",asset.sha256],["output->>bytes",String(asset.bytes)],["output->>mime",asset.content_type]]);
            return{data:control.candidate?[{id:f.evidence}]:[],error:control.lookupError?{}:null};
          }
          assertEquals(table,"upload_reservations");assertEquals(query.filters,[["asset_id",asset.id],["actor_id",f.actor]]);
          return{data:structuredClone(reservation),error:null};
        }};return chain;
    },
  };
  const run=()=>prepareAcceptedGalleryUpload(admin,f.actor,asset,undefined,f.io);
  return {...f,asset,reservation,scope,control,admin,run};
}

Deno.test("accepted gallery completion prepares exact retained bytes; replay preserves one copy and historical records",async()=>{
  const f=await fixture(), before=structuredClone(f.asset);
  await f.run();await f.run();
  assertEquals(f.state.phase,"prepared");assertEquals(f.state.claims,1);assertEquals(f.state.writes,1);
  assertEquals(f.asset,before);assertEquals({e:f.state.e,q:f.state.q,root:f.state.root},
    {e:f.history.e,q:f.history.q,root:f.history.root});
  assertEquals(f.state.reads.filter(x=>x===f.targetKey).length,2);
  assertEquals(f.state.calls.some(c=>/gallery|selection|serving_operation|quality_begin/.test(c.name)),false);
});
Deno.test("completion retries lost copy response without another dispatch or transport mutation",async()=>{
  const f=await fixture();f.state.unknownWrite=true;
  await assertRejects(f.run);assertEquals(f.asset.uploaded,true);assertEquals(f.state.phase,"preparing");
  f.state.unknownWrite=false;await f.run();assertEquals(f.state.writes,1);assertEquals(f.state.phase,"prepared");
});
Deno.test("completion retries finish refusal with the same copy and does not publish early",async()=>{
  const f=await fixture();f.state.finishError="RP409: Retained copy is unavailable";
  await assertRejects(f.run);assertEquals(f.state.phase,"preparing");
  f.state.finishError=null;await f.run();assertEquals(f.state.writes,1);assertEquals(f.state.phase,"prepared");
});
Deno.test("ordinary gallery upload avoids body reads and source-copy work",async()=>{
  const f=await fixture();f.control.candidate=false;await f.run();
  assertEquals(f.control.queries.length,1);assertEquals(f.state.calls,[]);assertEquals(f.state.reads,[]);assertEquals(f.state.writes,0);
});
Deno.test("default-role retained output never triggers gallery preparation",async()=>{
  const f=await fixture();f.asset.storage_key=f.targetKey.replace("gallery-","");await f.run();
  assertEquals(f.control.queries,[]);assertEquals(f.state.calls,[]);
});
for(const [label,change]of Object.entries({
  actor:(f:any):unknown=>f.reservation.actor_id=publicationID(90),org:(f:any):unknown=>f.reservation.org_id=publicationID(90),
  listing:(f:any):unknown=>f.reservation.listing_id=publicationID(90),role:(f:any):unknown=>f.reservation.spec.key_role="default",
  pending:(f:any):unknown=>f.reservation.state="open",bytes:(f:any):unknown=>f.reservation.spec.bytes++,
  readonly:(f:any):unknown=>f.scope.can_write=false,library:(f:any):unknown=>f.scope.library_org_id=publicationID(90),
}))Deno.test(`completion refuses changed ${label} authority before publication`,async()=>{
  const f=await fixture();change(f);await assertRejects(f.run);assertEquals(f.state.writes,0);assertEquals(f.state.phase,null);
});
for(const reason of ["RP404: This saved photo is unavailable for publication","RP409: Ambiguous accepted photo","RP409: This photo or its original was withdrawn"])
Deno.test("completion preserves canonical refusal: "+reason,async()=>{
  const f=await fixture();f.state.resolveError=reason;await assertRejects(f.run);assertEquals(f.state.writes,0);
});
for(const [label,change]of Object.entries({
  targetHash:(f:any):unknown=>f.stored.get(f.targetKey).body=f.input,
  targetMissing:(f:any):unknown=>f.stored.delete(f.targetKey),
  targetETag:(f:any):unknown=>f.stored.get(f.targetKey).etag='"changed"',
  retainedHash:(f:any):unknown=>f.stored.get(f.outputKey).body=f.input,
  retainedMissing:(f:any):unknown=>f.stored.delete(f.inputKey),
  targetMIME:(f:any):unknown=>f.state.target.mime="image/png",
  lookup:(f:any):unknown=>f.control.lookupError=true,
  noAcceptedSource:(f:any):unknown=>f.state.ordinary=true,
}))Deno.test(`completion refuses ${label}; matching metadata is never proof`,async()=>{
  const f=await fixture();change(f);await assertRejects(f.run);assertEquals(f.state.writes,0);assertEquals(f.state.phase,null);
});
Deno.test("aborted completion never starts publication",async()=>{
  const f=await fixture(),controller=new AbortController();controller.abort();
  await assertRejects(()=>prepareAcceptedGalleryUpload(f.admin,f.actor,f.asset,controller.signal,f.io));
  assertEquals(f.state.writes,0);
});
