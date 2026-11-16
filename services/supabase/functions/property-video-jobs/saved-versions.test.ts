import {assert,assertEquals,assertRejects} from 'jsr:@std/assert';
import {savedVersionSources} from './saved-versions.ts';

const actor='11111111-1111-4111-8111-111111111111';
const org='22222222-2222-4222-8222-222222222222';
const listing='33333333-3333-4333-8333-333333333333';
const library='44444444-4444-4444-8444-444444444444';
const assetID='55555555-5555-4555-8555-555555555555';
const sourceID='66666666-6666-4666-8666-666666666666';
const publicationID='77777777-7777-4777-8777-777777777777';
const evidenceID='88888888-8888-4888-8888-888888888888';
const checkID='99999999-9999-4999-8999-999999999999';
const copyID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const other='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
type Row=Record<string,any>;

function fixture(mode='pair'){
 const asset:Row={id:assetID,kind:'photo',bucket:'renders',storage_key:`renders/${org}/${listing}/gallery-${assetID}.jpg`,bytes:1234,sha256:'a'.repeat(64),content_type:'image/jpeg',uploaded:true,upload_aborted:false};
 const qc={publishable:true,action:'accept',output_sha256:asset.sha256,evidence_id:evidenceID,check_id:checkID,verdict:'fail',enforcement:'advisory'};
 const source:Row={id:sourceID,org_id:org,listing_id:listing,kind:'virtual_stage',original_key:`uploads/${org}/${listing}/${other}.jpg`,altered_key:asset.storage_key,disclosure:'Virtually staged with AI.',qc:structuredClone(qc),photo_publication:null};
 const publication:Row={...structuredClone(source),id:publicationID,original_key:`renders/${org}/${listing}/original-${copyID}.jpg`,photo_publication:{schema:1,phase:'prepared',source:{actor_id:actor,org_id:org,library_org_id:library,listing_id:listing,provenance_id:sourceID,evidence_id:evidenceID,automatic_check_id:checkID},target:{org_id:org,library_org_id:library,listing_id:listing,output_asset_id:assetID,source_copy_asset_id:copyID},output:{sha256:asset.sha256,bytes:asset.bytes,mime:asset.content_type}}};
 const rows:Row[]=mode==='original'?[]:mode==='single-source'?[source]:mode==='single-publication'?[publication]:[source,publication];
 const originals=mode==='original'?[{id:other,original_key:asset.storage_key}]:[];
 const target:Row={actor_id:actor,org_id:org,library_org_id:library,listing_id:listing,target:{asset_id:assetID,key:asset.storage_key,bytes:asset.bytes,sha256:asset.sha256,mime:asset.content_type},publication:mode==='original'||mode==='single-source'?null:{id:publicationID,photo_publication:structuredClone(publication.photo_publication)}};
 const owned:Row={actor_id:actor,org_id:org,listing_id:listing,asset_id:assetID,bucket:'renders',storage_key:asset.storage_key,bytes:asset.bytes,sha256:asset.sha256,content_type:asset.content_type};
 const state={scopeReads:0,changedScope:false,failTarget:false,failReference:false,failHead:false,failPreview:false,events:[]as string[],rpc:[]as {name:string;args:Row}[],heads:0,previews:0};
 const io={
  db:{from:(table:string)=>{
   const query:any={select:()=>query,eq:()=>query,in:()=>query,like:()=>query,order:()=>query,
    range:async()=>{assertEquals(table,'capture_assets');return{data:[asset],count:1,error:null};},
    limit:async()=>{assert(['media_provenance','photos'].includes(table));return{data:table==='media_provenance'?rows:originals,error:null};}};
   return query;
  }},
  scope:async(a:string,l:string,i:string,write:boolean)=>{assertEquals([a,l,i,write],[actor,library,listing,true]);state.scopeReads++;state.events.push('scope');return state.changedScope&&state.scopeReads>1?other:org;},
  rpc:async(name:string,args:Row)=>{state.rpc.push({name,args});state.events.push(name);if(name==='photo_publication_target'){assertEquals(args,{p_actor:actor,p_org:org,p_library:library,p_listing:listing,p_asset:assetID});if(state.failTarget)throw Error('Canonical publication unavailable.');return target;}assertEquals(name,'property_photo_reference');assertEquals([args.p_actor,args.p_listing,args.p_asset],[actor,listing,assetID]);if(state.failReference)throw Error('Accepted source is no longer available.');return owned;},
  head:async(s:Row)=>{assertEquals(s,owned);state.heads++;state.events.push('head');if(state.failHead)throw Error('Stored bytes changed.');},
  preview:async(s:Row)=>{assertEquals(s,{actor,org,listing,asset_id:assetID,bucket:'renders',key:asset.storage_key});state.previews++;state.events.push('preview');if(state.failPreview)throw Error('Private media unavailable.');return'https://fixture.invalid/private-photo';},
 };
 return{asset,source,publication,rows,originals,target,owned,state,io,run:()=>savedVersionSources(actor,listing,library,0,io)};
}

function unknown(result:Awaited<ReturnType<typeof savedVersionSources>>,message?:string){
 const row=result.sources[0];assertEquals({kind:row.version_kind,prepare:row.needs_preparation,eligible:row.eligible,provenance:row.photo_provenance_id,preview:row.preview_url},{kind:'unknown',prepare:false,eligible:false,provenance:null,preview:null},message);
}

Deno.test('saved gallery exact source→publication pair keeps canonical reference, physical HEAD and private preview in either row order',async()=>{
 for(const bucket of['uploads','renders'])for(const reverse of[false,true]){
  const f=fixture();f.source.original_key=f.source.original_key.replace(/^uploads\//,bucket+'/');if(reverse)f.rows.reverse();assert(f.source.original_key!==f.publication.original_key);const before=JSON.stringify([f.asset,f.rows]);const result=await f.run();
  assertEquals(result.sources[0].version_kind,'stage');assertEquals(result.sources[0].photo_provenance_id,publicationID);assertEquals(result.sources[0].needs_preparation,true);assertEquals(result.sources[0].eligible,false);
  assertEquals(f.state.rpc[1].args.p_provenance,publicationID);assertEquals(f.state.events,['scope','photo_publication_target','property_photo_reference','head','preview','scope']);assertEquals(JSON.stringify([f.asset,f.rows]),before);
 }
});

Deno.test('original and prior single-row saved versions retain their existing classification',async()=>{
 for(const mode of['original','single-source','single-publication']){
  const f=fixture(mode);const result=await f.run();assertEquals(result.sources[0].version_kind,mode==='original'?'original':'stage');assertEquals(result.sources[0].photo_provenance_id,mode==='original'?null:mode==='single-source'?sourceID:publicationID);assertEquals(f.state.heads,1);assertEquals(f.state.previews,1);
 }
});

Deno.test('third rows and false publication pairs never reach canonical RPC, HEAD or preview',async()=>{
 const mutations:[string,(f:ReturnType<typeof fixture>)=>void][]=[
  ['third row',f=>f.rows.push({...structuredClone(f.source),id:other})],
  ['two publications',f=>f.source.photo_publication=structuredClone(f.publication.photo_publication)],
  ['wrong source link',f=>f.publication.photo_publication.source.provenance_id=other],
  ['wrong evidence',f=>f.publication.photo_publication.source.evidence_id=other],
  ['wrong check',f=>f.publication.photo_publication.source.automatic_check_id=other],
  ['wrong actor',f=>f.publication.photo_publication.source.actor_id=other],
  ['wrong source library',f=>f.publication.photo_publication.source.library_org_id=other],
  ['wrong target library',f=>f.publication.photo_publication.target.library_org_id=other],
  ['wrong source listing',f=>f.publication.photo_publication.source.listing_id=other],
  ['wrong target asset',f=>f.publication.photo_publication.target.output_asset_id=other],
  ['wrong target org',f=>f.publication.photo_publication.target.org_id=other],
  ['wrong source org',f=>f.source.org_id=other],
  ['wrong source row listing',f=>f.source.listing_id=other],
  ['wrong hash',f=>f.publication.photo_publication.output.sha256='b'.repeat(64)],
  ['wrong bytes',f=>f.publication.photo_publication.output.bytes++],
  ['wrong MIME',f=>f.publication.photo_publication.output.mime='image/png'],
  ['not prepared',f=>f.publication.photo_publication.phase='preparing'],
  ['wrong schema',f=>f.publication.photo_publication.schema=2],
  ['source not accepted',f=>f.source.qc.action='hold'],
  ['source not publishable',f=>f.source.qc.publishable=false],
  ['source QC hash changed',f=>f.source.qc.output_sha256='b'.repeat(64)],
  ['different edit kind',f=>f.publication.kind='declutter'],
  ['missing accepted original',f=>f.source.original_key=null],
  ['publication original outside target',f=>f.publication.original_key=`renders/${other}/${listing}/original-${copyID}.jpg`],
  ['different disclosure',f=>f.publication.disclosure='Another disclosure.'],
 ];
 for(const[name,mutate]of mutations){const f=fixture();mutate(f);unknown(await f.run(),name);assertEquals([f.state.rpc.length,f.state.heads,f.state.previews],[0,0,0],name);}
});

Deno.test('a changed canonical target or source link cannot inherit the provisional pair classification',async()=>{
 const mutations:[string,(f:ReturnType<typeof fixture>)=>void][]=[
  ['wrong canonical publication',f=>f.target.publication.id=sourceID],
  ['canonical source link changed',f=>f.target.publication.photo_publication.source.provenance_id=other],
  ['canonical evidence changed',f=>f.target.publication.photo_publication.source.evidence_id=other],
  ['canonical check changed',f=>f.target.publication.photo_publication.source.automatic_check_id=other],
  ['wrong target actor',f=>f.target.actor_id=other],
  ['wrong target listing',f=>f.target.listing_id=other],
  ['wrong target receipt key',f=>f.target.target.key+='-other'],
  ['wrong target receipt hash',f=>f.target.target.sha256='b'.repeat(64)],
 ];
 for(const[name,mutate]of mutations){const f=fixture();mutate(f);unknown(await f.run(),name);assertEquals([f.state.heads,f.state.previews],[0,0],name);}
});

Deno.test('canonical owned-reference identities and body checks still gate every paired source',async()=>{
 for(const field of['actor_id','org_id','listing_id','asset_id','storage_key','bytes','sha256','content_type']){
  const f=fixture();f.owned[field]=field==='bytes'?1235:field==='sha256'?'b'.repeat(64):field==='storage_key'?f.asset.storage_key+'-other':field==='content_type'?'image/png':other;unknown(await f.run(),field);assertEquals([f.state.heads,f.state.previews],[0,0],field);
 }
});

Deno.test('accepted-source revocation, canonical lookup, physical HEAD and private-preview failures stay unavailable',async()=>{
 for(const failure of['failTarget','failReference','failHead','failPreview']as const){const f=fixture();f.state[failure]=true;unknown(await f.run(),failure);}
});

Deno.test('final library revocation discards a paired catalogue even after physical validation',async()=>{
 const f=fixture();f.state.changedScope=true;await assertRejects(()=>f.run());assertEquals([f.state.heads,f.state.previews,f.state.scopeReads],[1,1,2]);
});
