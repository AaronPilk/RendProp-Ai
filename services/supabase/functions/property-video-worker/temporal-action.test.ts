// The ACTUAL worker extract_frames action asks the renderer for the temporal
// motion report on steady profiles only (temporal.ts), with closed media/scope
// boundaries. Historical profiles keep their byte-identical task.
import{assert,assertEquals,assertThrows}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE}from'../ai-video/property-video-quality.ts';
import{KIE_PROPERTY_PROFILE}from'../_shared/property-video-kie.ts';
import{TEMPORAL_QC_PROFILE,temporalTask}from'./temporal.ts';
const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
const engine=await Deno.readTextFile(new URL('./engine.ts',import.meta.url));
const actionStart=engine.indexOf('export async function action(');assert(actionStart>0,'actual CPU action entry point');
let state:any;(globalThis as any).__temporalActionFixture=()=>state;
const prefix=`
import{KIE_PROPERTY_PROFILE}from ${href('../_shared/property-video-kie.ts')};
import{temporalTask}from ${href('./temporal.ts')};
type WorkerAction=any;type ComposeAction=any;
const PROPERTY_VIDEO_STEADY_PROFILE=${JSON.stringify(PROPERTY_VIDEO_STEADY_PROFILE)};
const f=()=>globalThis.__temporalActionFixture();
const scope=async(...args)=>{f().scopes.push(args);};
const seconds=(n)=>'closed-expiry-'+n;
const media=async(c,ttl=600)=>({url:'closed-signed:'+c.storage_key+':'+ttl,sha256:c.sha256,bytes:c.bytes,etag:c.etag});
const bytesFrom=async()=>{throw Error('closed: extract_frames reads no bytes in the worker');};
const assert=(ok,status,message)=>{if(!ok)throw Error(status+': '+message);};
const rpc=async(name,args)=>{f().rpcs.push({name,args});return{};};
const headObject=async()=>{throw Error('closed');};const bucket=(x)=>x;const adminClient=()=>{throw Error('closed: extract_frames touches no table');};
`;
const{action}=await import('data:application/typescript,'+encodeURIComponent(prefix+engine.slice(actionStart)));
const ctx=(profile:string|undefined,aspect='16:9')=>({action:'extract_frames',job:{id:'job',quality_profile:profile,manifest:{aspect}},source:{attempt_id:'attempt',lease_token:'lease',asset_id:'asset',source:{bucket:'uploads',storage_key:'photo.jpg',sha256:'f'.repeat(64),bytes:50,etag:'"p"'},clip:{bucket:'renders',storage_key:'clip.mp4',sha256:'e'.repeat(64),bytes:100,etag:'"c"'}}});
const HISTORICAL=JSON.stringify({job_id:'job',state:'quality_review',action:'extract_frames',attempt_id:'attempt',lease_token:'lease',source:{url:'closed-signed:photo.jpg:600',sha256:'f'.repeat(64),bytes:50,etag:'"p"',asset_id:'asset'},clip:{url:'closed-signed:clip.mp4:600',sha256:'e'.repeat(64),bytes:100,etag:'"c"'},expires_at:'closed-expiry-240'});
Deno.test('steady profiles request temporal-motion-v2 in the final aspect; legacy and v1 tasks are byte-identical to before',async()=>{
 for(const profile of[PROPERTY_VIDEO_STEADY_PROFILE,KIE_PROPERTY_PROFILE])for(const aspect of['16:9','9:16']){
  state={scopes:[],rpcs:[]};const out=await action(ctx(profile,aspect));
  assertEquals(out.temporal_qc,{profile:TEMPORAL_QC_PROFILE,aspect});assertEquals(state.scopes,[['job','lease','attempt']]);
  const{temporal_qc:_t,...rest}=out;assertEquals(JSON.stringify(rest),HISTORICAL);
 }
 for(const profile of[undefined,'legacy',PROPERTY_VIDEO_QUALITY_PROFILE]){state={scopes:[],rpcs:[]};const out=await action(ctx(profile));assertEquals(JSON.stringify(out),HISTORICAL,String(profile));assert(!('temporal_qc'in out));}
});
Deno.test('the request builder is closed: steady needs a final aspect, other profiles get nothing',()=>{
 assertEquals(temporalTask('legacy','16:9'),{});assertEquals(temporalTask(undefined,'9:16'),{});assertEquals(temporalTask(PROPERTY_VIDEO_QUALITY_PROFILE,'16:9'),{});
 assertEquals(temporalTask(PROPERTY_VIDEO_STEADY_PROFILE,'9:16'),{temporal_qc:{profile:'temporal-motion-v2',aspect:'9:16'}});
 assertThrows(()=>temporalTask(KIE_PROPERTY_PROFILE,'4:3'));assertThrows(()=>temporalTask(KIE_PROPERTY_PROFILE,undefined));
});
