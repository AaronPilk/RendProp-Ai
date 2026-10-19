// Kie native-4K profile through the ACTUAL worker CPU actions (inspect_audio,
// compose), the finish route of index.ts and the trusted ai-video scope. Code is
// compiled from the real files with closed DB/R2/probe boundaries; each Kie
// guard has a compiled defect control that must fail the same oracle.
import{assert,assertEquals,assertRejects,assertThrows}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE}from'../ai-video/property-video-quality.ts';
import{KIE_PROPERTY_IDENTITY,KIE_PROPERTY_PROFILE,sameKiePropertyIdentity}from'../_shared/property-video-kie.ts';

const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
const engine=await Deno.readTextFile(new URL('./engine.ts',import.meta.url));
let instances=0;
const load=async(code:string)=>await import('data:application/typescript,'+encodeURIComponent(code+`\n// instance ${instances++}`));
const once=(source:string,text:string)=>{assertEquals(source.split(text).length,2,'exact actual text: '+text);return text;};
const HISTORICAL=[undefined,'legacy',PROPERTY_VIDEO_QUALITY_PROFILE] as const;

Deno.test('the frozen Kie identity names exactly the composition contract the worker sends',()=>{
 assertEquals([KIE_PROPERTY_IDENTITY.composition_profile,KIE_PROPERTY_IDENTITY.output_fps,[...KIE_PROPERTY_IDENTITY.output_frames],KIE_PROPERTY_IDENTITY.seconds],['steady-v2-cfr24',24,[120,121],5]);
});

// ---- inspect_audio / compose ------------------------------------------------
const actionStart=engine.indexOf('export async function action(');assert(actionStart>0,'actual CPU action entry point');
const actionSource=engine.slice(actionStart);
let actionState:any;
(globalThis as any).__kieActionFixture=()=>actionState;
const actionPrefix=`
import{KIE_PROPERTY_PROFILE}from ${href('../_shared/property-video-kie.ts')};
type WorkerAction=any;type ComposeAction=any;
const PROPERTY_VIDEO_STEADY_PROFILE=${JSON.stringify(PROPERTY_VIDEO_STEADY_PROFILE)};
const f=()=>globalThis.__kieActionFixture();
const scope=async(...args)=>{f().scopes.push(args);};
const seconds=(n)=>'closed-expiry-'+n;
const media=async(c,ttl=600)=>({url:'closed-signed:'+c.storage_key+':'+ttl,sha256:c.sha256,bytes:c.bytes,etag:c.etag});
const bytesFrom=async(c)=>{f().reads.push(c.storage_key);return{sha256:c.sha256};};
const assert=(ok,status,message)=>{if(!ok)throw Error(status+': '+message);};
const rpc=async(name,args)=>{f().rpcs.push({name,args});return{};};
const headObject=async()=>{throw Error('closed: saved own narration needs no HEAD');};
const bucket=(x)=>x;
const ROWS={property_video_audio_assets:{state:'ready',storage_key:'saved-voice.m4a',bytes:12,sha256:'${'a'.repeat(64)}',etag:'"voice"',mime:'audio/mp4'},property_video_music_catalog:{track_id:'calm',storage_key:'music/calm.m4a',bytes:34,sha256:'${'b'.repeat(64)}',etag:'"music"',license_evidence_sha256:'${'c'.repeat(64)}',credit:'CC0 fixture'},property_video_preparations:null};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>({error:null,data:ROWS[table]})};return q;}});
`;
const realAction=await load(actionPrefix+actionSource);
const TRANSITIONS=['dissolve','whip','cut'] as const;
const job=(profile:string|undefined,transition:string='dissolve',sourceCount=2)=>({id:'job',org_id:'org',listing_id:'listing',actor_id:'actor',state:'composing',quality_profile:profile,source_count:sourceCount,manifest_sha256:'d'.repeat(64),compose_lease:'compose-lease',audio_lease:'audio-lease',output_asset_id:'out',poster_asset_id:'poster',
 manifest:{purpose:'listing',aspect:'16:9',presentation:{transition,shot_caption_style:'off',spoken_captions:false,title_card:null,shot_labels:[null,null]},narration_asset_id:'voice',narration_words:[{text:'Welcome',start:0,end:1}],music:{track_id:'calm',asset_sha256:'b'.repeat(64),license_id:'CC0-1.0',license_evidence_sha256:'c'.repeat(64),gain:0.4,duck_gain:0.2}}});
const SOURCES=[{position:0,state:'ready',clip:{bucket:'renders',storage_key:'clip-0.mp4',sha256:'e'.repeat(64),bytes:100,etag:'"c0"'},motion:'push_in'},{position:1,state:'original_photo',source:{bucket:'uploads',storage_key:'photo-1.jpg',sha256:'f'.repeat(64),bytes:50,etag:'"p1"'},motion:'side_glide'}];
async function act(module:any,kind:'compose'|'inspect_audio',profile:string|undefined,transition='dissolve',sourceCount=2){
 actionState={scopes:[],reads:[],rpcs:[]};const out=await module.action({action:kind,job:job(profile,transition,sourceCount),sources:SOURCES});return{out,...actionState};
}
// The pre-Kie (base 462e4c8) compose task for a 30 fps profile, key order included.
const HISTORICAL_COMPOSE=JSON.stringify({job_id:'job',state:'composing',action:'compose',lease_token:'compose-lease',manifest_sha256:'d'.repeat(64),purpose:'listing',aspect:'16:9',
 sources:[{url:'closed-signed:clip-0.mp4:1800',sha256:'e'.repeat(64),bytes:100,etag:'"c0"',position:0,motion_kind:'ai',motion:'push_in'},{url:'closed-signed:photo-1.jpg:1800',sha256:'f'.repeat(64),bytes:50,etag:'"p1"',position:1,motion_kind:'original_photo',motion:'side_glide'}],
 narration:{url:'closed-signed:saved-voice.m4a:1800',sha256:'a'.repeat(64),bytes:12,etag:'"voice"',words:[{text:'Welcome',start:0,end:1}],kind:'own'},
 music:{url:'closed-signed:music/calm.m4a:1800',sha256:'b'.repeat(64),bytes:34,etag:'"music"',track_id:'calm',asset_sha256:'b'.repeat(64),license_id:'CC0-1.0',license_evidence_sha256:'c'.repeat(64),gain:0.4,duck_gain:0.2,license_revision:'c'.repeat(64),credit:'CC0 fixture'},
 presentation:{transition:'dissolve',shot_caption_style:'off',spoken_captions:false,title_card:null,shot_labels:[null,null]},
 output:{asset_id:'out',key:'renders/org/listing/background/job/compose-lease/master.mp4',poster_asset_id:'poster',poster_key:'renders/org/listing/background/job/compose-lease/first-clip.jpg'},expires_at:'closed-expiry-1800'});
/** Same task with only the native-24 composition profile added right after aspect. */
const STEADY_COMPOSE=JSON.stringify(Object.fromEntries(Object.entries(JSON.parse(HISTORICAL_COMPOSE)).flatMap(([k,v])=>k==='aspect'?[[k,v],['composition_profile','steady-v2-cfr24']]:[[k,v]])));
const maxDuration=(n:number,fps:24|30,transition:string)=>5*n-(n-1)*({dissolve:fps===24?6:8,whip:fps===24?4:5,cut:0} as Record<string,number>)[transition]/fps;

async function kieComposesExactlyLikeSteady(module:any){
 for(const profile of[KIE_PROPERTY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE]){const r=await act(module,'compose',profile);assertEquals(JSON.stringify(r.out),STEADY_COMPOSE,profile);}
 for(const profile of HISTORICAL){const r=await act(module,'compose',profile);assertEquals(JSON.stringify(r.out),HISTORICAL_COMPOSE,String(profile));assert(!('composition_profile'in r.out));}
}
async function kieAudioLimitIsSteady24(module:any){
 for(const transition of TRANSITIONS)for(const n of[1,2,20,100]){
  const kie=await act(module,'inspect_audio',KIE_PROPERTY_PROFILE,transition,n),steady=await act(module,'inspect_audio',PROPERTY_VIDEO_STEADY_PROFILE,transition,n);
  assertEquals(kie.out.max_duration_s,maxDuration(n,24,transition),`kie ${transition} x${n}`);assertEquals(JSON.stringify(kie.out),JSON.stringify(steady.out));assertEquals(kie.rpcs,steady.rpcs);
  for(const profile of HISTORICAL)assertEquals((await act(module,'inspect_audio',profile,transition,n)).out.max_duration_s,maxDuration(n,30,transition),`${profile} ${transition} x${n}`);
 }
}
Deno.test('compose sends steady-v2-cfr24 for Kie and FAL steady only; historical profiles keep the byte-identical task',async()=>{
 await kieComposesExactlyLikeSteady(realAction);
 const r=await act(realAction,'compose',KIE_PROPERTY_PROFILE);assertEquals(r.scopes,[['job','compose-lease']]);assertEquals(r.out.composition_profile,KIE_PROPERTY_IDENTITY.composition_profile);
 // Defect controls: Kie left out of the steady set, or the profile spread removed.
 const steadyLine=once(actionSource,'const steady=j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE||j.quality_profile===KIE_PROPERTY_PROFILE;');
 const falOnly=await load(actionPrefix+actionSource.replace(steadyLine,'const steady=j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE;'));
 await assertRejects(()=>kieComposesExactlyLikeSteady(falOnly),Error,undefined,'control: Kie silently composed at 30 fps');
 const noProfile=await load(actionPrefix+actionSource.replace(once(actionSource,"...(steady?{composition_profile:'steady-v2-cfr24' as const}:{}),"),''));
 await assertRejects(()=>kieComposesExactlyLikeSteady(noProfile),Error,undefined,'control: composition profile omitted');
});
Deno.test('inspect_audio narration limit for Kie equals FAL steady (24 fps, 6/4-frame joins); historical profiles keep 30 fps math',async()=>{
 await kieAudioLimitIsSteady24(realAction);
 assertEquals((await act(realAction,'inspect_audio',KIE_PROPERTY_PROFILE,'dissolve',2)).out.max_duration_s,10-6/24);
 assertEquals((await act(realAction,'inspect_audio','legacy','dissolve',2)).out.max_duration_s,10-8/30);
 const falOnly=await load(actionPrefix+actionSource.replace(once(actionSource,'const steady=j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE||j.quality_profile===KIE_PROPERTY_PROFILE;'),'const steady=j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE;'));
 await assertRejects(()=>kieAudioLimitIsSteady24(falOnly),Error,undefined,'control: Kie narration limit falls back to 30 fps');
});

// ---- finish (index.ts) --------------------------------------------------------
const indexUrl=new URL('./index.ts',import.meta.url),indexSource=await Deno.readTextFile(indexUrl);
const REAL_IMPORTS=new Set(['../_shared/http.ts','../_shared/property-video-kie.ts','../property-video-jobs/input.ts']);
async function loadIndex(source:string){
 let imports=0;
 const code=source.replace(/^import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\2;?/gm,(_m,names:string,_q:string,path:string)=>{imports++;return REAL_IMPORTS.has(path)?`import{${names}}from${JSON.stringify(new URL(path,indexUrl).href)};`:`const{${names}}=globalThis.__kieFinishStubs;`;});
 assert(imports>=14&&code.split('\n').filter(l=>/^import/.test(l)).every(l=>l.includes('from"file://')),'every actual worker import is either real or closed');
 return await load(code);
}
const F={job:'f7000000-0000-4000-8000-000000000001',lease:'f7000000-0000-4000-8000-000000000002',asset:'f7000000-0000-4000-8000-000000000003',poster:'f7000000-0000-4000-8000-000000000004'};
let finishState:any;
const closed=(name:string)=>()=>{throw new Error('closed worker boundary: '+name);};
(globalThis as any).__kieFinishStubs={
 PROPERTY_VIDEO_STEADY_PROFILE,
 adminClient:()=>({from:(table:string)=>{const result=table==='property_video_job_outputs'?{error:null,data:finishState.outputs}:{error:null,data:null};const q:any={select:()=>q,eq:()=>q,maybeSingle:async()=>result,then:(ok:any,ko:any)=>Promise.resolve(result).then(ok,ko)};return q;}}),
 isServiceRole:()=>true,
 probeComposedMP4Video:async(url:string,fetcher:unknown,expectedFPS:24|30)=>{finishState.probes.push({url,expectedFPS,globalFetch:fetcher===globalThis.fetch});return{width:1920,height:1080,duration_s:10,billable_s:10,fps:expectedFPS};},
 presignGet:async(which:string,key:string,ttl:number)=>`https://closed-signed.invalid/${which}/${key}?ttl=${ttl}`,
 R2_BUCKET_RENDERS:'closed-renders',
 rpc:async(name:string,args:any)=>{finishState.rpcs.push({name,args});if(name==='property_video_job_scope')return{state:'composing'};if(name==='property_video_job_finish')return{...finishState.job,state:'ready',result:args.p_facts};throw new Error('unexpected rpc '+name);},
 reply:async(j:any)=>({job_id:j.id,state:j.state}),
 bytesFrom:async(c:any)=>({bytes:new Uint8Array([255,216,255,224]),sha256:c.sha256}),
 putCapability:closed('putCapability'),
 outputHead:async(_which:string,key:string)=>{const o=finishState.outputs.find((x:any)=>x.storage_key===key);return{bytes:o.bytes,sha256:o.sha256,contentType:o.content_type,etag:`"${o.kind}-etag"`};},
 preparationTick:closed('preparationTick'),preparationWorker:closed('preparationWorker'),
 action:closed('action'),dispatch:closed('dispatch'),poll:closed('poll'),quality:closed('quality'),
 scope:async(id:string,lease:string)=>{finishState.scopes.push([id,lease]);return{job:finishState.job};},
 releaseCancelledProviderSlots:closed('releaseCancelledProviderSlots'),providerDiagnostic:closed('providerDiagnostic'),
};
async function finish(module:any,profile:string|undefined){
 const key=(name:string)=>`renders/org/listing/background/${F.job}/${F.lease}/${name}`;
 finishState={job:{id:F.job,manifest_sha256:'a'.repeat(64),output_asset_id:F.asset,poster_asset_id:F.poster,quality_profile:profile},
  outputs:[{kind:'video',storage_key:key('master.mp4'),bytes:1000,sha256:'b'.repeat(64),content_type:'video/mp4'},{kind:'poster',storage_key:key('first-clip.jpg'),bytes:4,sha256:'c'.repeat(64),content_type:'image/jpeg'}],probes:[],rpcs:[],scopes:[]};
 const body={job_id:F.job,lease_token:F.lease,manifest_sha256:'a'.repeat(64),asset_id:F.asset,poster_asset_id:F.poster,width:1920,height:1080,duration_s:10};
 const response=await module.handler(new Request('https://functions.invalid/property-video-worker/finish',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));
 return{status:response.status,body:await response.json(),...finishState};
}
const finishedFacts=(r:any)=>r.rpcs.find((x:any)=>x.name==='property_video_job_finish')?.args.p_facts;
function finishedAt(fps:24|30,r:any){
 assertEquals(r.status,200,JSON.stringify(r.body));assertEquals(r.probes.map((p:any)=>p.expectedFPS),[fps]);assert(r.probes[0].globalFetch);
 const facts=finishedFacts(r);assert(facts,'finish RPC recorded');
 if(fps===24)assertEquals(facts.fps,24);else assert(!('fps'in facts),'30 fps profiles keep their exact facts shape');
}
Deno.test('finish verifies Kie and FAL steady masters as native 24 fps and every other profile at 30',async()=>{
 const real=await loadIndex(indexSource);
 const kie=await finish(real,KIE_PROPERTY_PROFILE),steady=await finish(real,PROPERTY_VIDEO_STEADY_PROFILE);
 finishedAt(24,kie);finishedAt(24,steady);assertEquals(finishedFacts(kie),finishedFacts(steady));
 assertEquals(kie.rpcs.map((x:any)=>x.name),['property_video_job_scope','property_video_job_finish']);assertEquals(kie.scopes,[[F.job,F.lease],[F.job,F.lease]]);
 const{fps:_fps,...withoutFps}=finishedFacts(steady);
 for(const profile of HISTORICAL){const r=await finish(real,profile);finishedAt(30,r);assertEquals(finishedFacts(r),withoutFps);}
 // Defect control: finish compiled with only the FAL steady profile at 24 fps.
 const steadyLine=once(indexSource,'const steady=ctx.job.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE||ctx.job.quality_profile===KIE_PROPERTY_PROFILE;');
 const falOnly=await loadIndex(indexSource.replace(steadyLine,'const steady=ctx.job.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE;'));
 const wrong=await finish(falOnly,KIE_PROPERTY_PROFILE);assertThrows(()=>finishedAt(24,wrong),Error,undefined,'control: Kie master probed as CFR30');
});

// ---- trusted ai-video scope -------------------------------------------------
const scopeStart=engine.indexOf('async function aiScope('),scopeEnd=engine.indexOf('\nasync function callAI(',scopeStart);
assert(scopeStart>0&&scopeEnd>scopeStart,'actual trusted scope projection');
const scopeSource=engine.slice(scopeStart,scopeEnd).replace('async function aiScope(','export async function aiScope(');
const scopePrefix=`import{KIE_PROPERTY_IDENTITY}from ${href('../_shared/property-video-kie.ts')};
type AiVideoWorkerScope=any;const closed=()=>{throw Error('closed');};const scope=closed,rpc=closed,adminClient=closed,assert=closed;
`;
/** Postgres jsonb object key order: UTF-8 byte length, then bytewise, at every level. */
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
const jsonbOrder=(value:unknown):any=>Array.isArray(value)?value.map(jsonbOrder):value&&typeof value==='object'
 ?Object.fromEntries(Object.keys(value).sort(byteOrder).map(k=>[k,jsonbOrder((value as Record<string,unknown>)[k])])):value;
/** What PostgREST returns for the frozen jsonb column: a plain parsed copy in jsonb key order, never the code constant. */
const frozenRow=()=>jsonbOrder(JSON.parse(JSON.stringify(KIE_PROPERTY_IDENTITY)));
async function scopeCarriesFrozenRow(module:any){
 const kieJob={actor_id:'actor',listing_id:'listing',manifest:{aspect:'9:16'},quality_profile:KIE_PROPERTY_PROFILE,quality_identity:frozenRow()};
 assertEquals(Object.keys(kieJob.quality_identity.prompt_template_sha256),['push_in','pull_back','side_glide','fly_through'],'fixture is in true jsonb order');
 const s=await module.aiScope({job:kieJob,source:{}});
 assertEquals(s.qualityProfile,KIE_PROPERTY_PROFILE);assert(s.qualityIdentity===kieJob.quality_identity,'the job row itself, not a substitute');assert(sameKiePropertyIdentity(s.qualityIdentity));
 // A changed frozen row reaches dispatch unchanged so dispatch refuses it; nothing repairs it.
 const{privacy_tier:_,...missingKey}=frozenRow();
 for(const tampered of[{...frozenRow(),mode:'pro'},{...frozenRow(),unit_cents:9},{...frozenRow(),route_id:'00000000-0000-4000-8000-000000000000'},{...frozenRow(),extra:true},missingKey]){
  const t=await module.aiScope({job:{...kieJob,quality_identity:tampered},source:{}});assert(t.qualityIdentity===tampered);assert(!sameKiePropertyIdentity(t.qualityIdentity));
 }
 for(const value of[null,undefined])assertEquals((await module.aiScope({job:{...kieJob,quality_identity:value},source:{}})).qualityIdentity,null);
 for(const profile of[...HISTORICAL,PROPERTY_VIDEO_STEADY_PROFILE]){const h=await module.aiScope({job:{...kieJob,quality_profile:profile,quality_identity:null},source:{}});assertEquals([h.qualityProfile,h.qualityIdentity],[profile??'legacy',null]);}
}
Deno.test('trusted ai-video scope carries the job row frozen identity verbatim (Kie) and null for historical profiles',async()=>{
 await scopeCarriesFrozenRow(await load(scopePrefix+scopeSource));
 const field=once(scopeSource,'qualityIdentity:j.quality_identity??null,');
 await assertRejects(async()=>await scopeCarriesFrozenRow(await load(scopePrefix+scopeSource.replace(field,''))),Error,undefined,'control: identity omitted');
 await assertRejects(async()=>await scopeCarriesFrozenRow(await load(scopePrefix+scopeSource.replace(field,'qualityIdentity:KIE_PROPERTY_IDENTITY,'))),Error,undefined,'control: identity laundered from code');
});
