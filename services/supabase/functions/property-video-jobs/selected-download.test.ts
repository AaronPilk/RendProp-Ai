import {assert,assertEquals,assertRejects} from 'jsr:@std/assert';
import {selectedVideoDownload} from './selected-download.ts';

const actor='11111111-1111-4111-8111-111111111111';
const library='22222222-2222-4222-8222-222222222222';
const org='33333333-3333-4333-8333-333333333333';
const listing='44444444-4444-4444-8444-444444444444';
const composition='55555555-5555-4555-8555-555555555555';
const asset='66666666-6666-4666-8666-666666666666';
const owner='77777777-7777-4777-8777-777777777777';
const key=`renders/${org}/${listing}/selected/master.mp4`;

function fixture(changes:Record<string,unknown>={}){
 let reads=0,scopeReads=0,heads=0,signs=0;
 const selection={composition_id:composition,asset_id:asset,storage_key:key,duration_s:8,branding_policy:'unbranded'};
 const row={id:composition,actor_id:owner,org_id:org,listing_id:listing,asset_id:asset,selected:true};
 const source={actor_id:owner,org_id:org,listing_id:listing,asset_id:asset,bucket:'renders' as const,storage_key:key,
  content_type:'video/mp4',bytes:1024,sha256:'a'.repeat(64),etag:'"selected"'};
 const deps={
  scope:async(a:string,l:string,i:string)=>{scopeReads++;if(a!==actor||l!==library||i!==listing)throw Error('Foreign account or listing.');return scopeReads>1&&changes.scopeChangedAfterSign?owner:org;},
  presentation:async(_i:string)=>{reads++;return reads>1&&changes.changedAfterSign?{...selection,asset_id:owner}:selection;},
  composition:async(_id:string)=>({...row,...changes}),
  owned:async(a:string,i:string,v:string)=>{assertEquals([a,i,v],[owner,listing,asset]);return {...source,...changes};},
  head:async()=>{heads++;},
  sign:async(s:unknown)=>{signs++;assertEquals(s,{actor,org,listing,bucket:'renders',key});return'https://rendprop.com/private-media/opaque';},
 };
 return {deps,counts:()=>({reads,scopeReads,heads,signs})};
}

Deno.test('selected website video uses only the scoped, currently selected owned output',async()=>{
 const f=fixture();
 const result=await selectedVideoDownload(actor,listing,library,f.deps);
 assertEquals(result.composition_id,composition);
 assertEquals(result.asset_id,asset);
 assertEquals(result.sha256,'a'.repeat(64));
 assertEquals(result.download_url,'https://rendprop.com/private-media/opaque');
 assertEquals(f.counts(),{reads:2,scopeReads:2,heads:1,signs:1});
});

Deno.test('wrong composition, listing, actor source or late selection never yields a file',async()=>{
 for(const changes of [{selected:false},{listing_id:owner},{asset_id:owner},{actor_id:actor},{storage_key:`renders/${org}/${listing}/other.mp4`},{changedAfterSign:true},{scopeChangedAfterSign:true}]){
  const f=fixture(changes);
  await assertRejects(()=>selectedVideoDownload(actor,listing,library,f.deps));
  assert(f.counts().signs===0||changes.changedAfterSign===true||changes.scopeChangedAfterSign===true);
 }
});

Deno.test('foreign account and stale selection never receive a download token',async()=>{
 const foreign=fixture();
 await assertRejects(()=>selectedVideoDownload(owner,listing,library,foreign.deps));
 assertEquals(foreign.counts(),{reads:0,scopeReads:1,heads:0,signs:0});

 const stale=fixture({changedAfterSign:true});
 let returned:unknown;
 try { returned=await selectedVideoDownload(actor,listing,library,stale.deps); }
 catch { returned=undefined; }
 assertEquals(returned,undefined);
 assertEquals(stale.counts(),{reads:2,scopeReads:1,heads:1,signs:1});
});
