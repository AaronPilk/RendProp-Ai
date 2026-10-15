import{assert,assertEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{HttpError}from'../_shared/http.ts';
const engine=await Deno.readTextFile(new URL('./engine.ts',import.meta.url)),start=engine.indexOf('export type PropertyVideoPollPhase='),end=engine.indexOf('\nexport async function quality(',start);
assert(start>0&&end>start);let state:any;
(globalThis as any).__propertyVideoPollFixture=()=>state;
const prefix=`
import{HttpError,assert}from ${JSON.stringify(new URL('../_shared/http.ts',import.meta.url).href)};
const f=()=>globalThis.__propertyVideoPollFixture();
const R2_BUCKET_RENDERS='closed-renders';
const callAI=async(_ctx,method,path)=>{f().methods.push(method);if(method!=='GET')throw Error('No supplier POST permitted');f().events.push('status');return f().response;};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{f().events.push(table);return table==='private_ai_outputs'?{error:null,data:f().owned?{storage_key:'owned-clip',bytes:100}:null}:{error:null,data:{provider_request_id:f().paid?'accepted-request':'wrong-request',model:'kling-3.0/video'}};}};return q;}});
const headObject=async()=>{f().events.push('head');return{exists:true,bytes:100,etag:'"immutable"',contentType:'video/mp4'};};
const presignGet=async()=>{f().events.push('sign');return'https://DO-NOT-LOG.invalid?token=SECRET';};
const probeRetainedProviderMP4Video=async()=>{f().events.push('probe');if(f().probeError)throw f().probeError;return f().facts;};
const bytesFrom=async()=>{f().events.push('bytes');return{bytes:new Uint8Array([1,2,3]),sha256:'exact-hash'};};
const base64=()=> 'AQID',driftLineageKey=async()=> 'exact-lineage';
const scope=async()=>{f().events.push('scope');if(f().scopeError)throw new HttpError(403,'PRIVATE-TOKEN-MUST-NOT-LOG');};
const rpc=async(name,args)=>{f().rpcs.push({name,args});if(name==='property_video_job_provenance')return{id:'owned-generation'};return true;};
const fail=async(_ctx,code,ambiguous=false)=>{f().fail.push({code,ambiguous});};
`;
const{poll,propertyVideoPollDiagnostic}=await import('data:application/typescript,'+encodeURIComponent(prefix+engine.slice(start,end)));
const ctx=()=>({job:{id:'owned-job',actor_id:'owned-actor',org_id:'owned-org',library_org_id:'selected-library',listing_id:'owned-listing',manifest:{aspect:'9:16'}},source:{attempt_id:'attempt',lease_token:'lease',request_key:'same-operation',asset_id:'same-source',source:{},photo_provenance_id:null,receipt:{request_id:'accepted-request',status_url:'https://private-receipt.invalid/status?job=SECRET'}}});
function reset(){state={response:{status:200,value:{status:'completed',persisted:true,asset_key:'owned-clip'}},owned:true,paid:true,probeError:null,facts:{width:1080,height:1920,duration_s:5,fps:30},methods:[],events:[],rpcs:[],fail:[],diagnostics:[]};}
async function run(){const old=console.warn;console.warn=(text:string)=>state.diagnostics.push(JSON.parse(text));try{await poll(ctx());}finally{console.warn=old;}}
Deno.test('retained completed clip checks exact owner and paid receipt before strict provider profile then advances only current source',async()=>{
 reset();await run();assertEquals(state.fail,[]);assertEquals(state.diagnostics,[]);assertEquals(state.methods,['GET']);
 assert(state.events.indexOf('private_ai_outputs')<state.events.indexOf('probe'));assert(state.events.indexOf('app_video_cost_reservations')<state.events.indexOf('probe'));assert(state.events.indexOf('scope')>state.events.indexOf('probe'));
 assertEquals(state.rpcs.map((r:any)=>r.name),['property_video_job_provenance','bind_property_video_source','property_video_job_clip','property_video_job_poll_release']);
 const clip=state.rpcs.find((r:any)=>r.name==='property_video_job_clip');assertEquals(clip.args.p_attempt,'attempt');assertEquals(clip.args.p_clip.width,1080);assertEquals(clip.args.p_clip.height,1920);
});
Deno.test('actual KIE1660px portrait facts fail native1080 canvas with no paid retry quality judge publication or still fallback',async()=>{
 reset();state.facts={width:1244,height:1660,duration_s:5.042,fps:24};await run();assertEquals(state.fail,[{code:'source_quality_below_1080',ambiguous:false}]);assertEquals(state.methods,['GET']);assertEquals(state.rpcs,[]);assert(!state.events.includes('bytes'));
});
Deno.test('deterministic malformed retained MP4 fails closed; transient range/network failures retain accepted operation',async()=>{
 reset();state.probeError=new HttpError(400,'SECRET https://private.invalid?token=DO-NOT-LOG');await run();assertEquals(state.fail,[{code:'source_video_unverifiable',ambiguous:false}]);assertEquals(state.rpcs,[]);assertEquals(state.methods,['GET']);assertEquals(state.diagnostics,[{event:'property_video_poll_failure',phase:'mp4_probe',error_name:'HttpError',http_status:400}]);
 for(const error of[new HttpError(409,'Changed range SECRET'),new TypeError('PRIVATE URL must not log')]){reset();state.probeError=error;await run();assertEquals(state.fail,[]);assertEquals(state.methods,['GET']);assertEquals(state.rpcs.map((r:any)=>r.name),['property_video_job_poll_release']);assertEquals(state.diagnostics[0].phase,'mp4_probe');assert(!JSON.stringify(state.diagnostics).includes('SECRET'));assert(!JSON.stringify(state.diagnostics).includes('PRIVATE'));}
});
Deno.test('foreign ownership mismatched paid receipt and revoked scope never advance or expose private media',async()=>{
 for(const fault of['owned','paid','scope']){reset();if(fault==='scope')state.scopeError=true;else state[fault]=false;await run();assertEquals(state.fail,[]);assertEquals(state.methods,['GET']);assert(!state.rpcs.some((r:any)=>r.name==='property_video_job_clip'));assertEquals(state.diagnostics[0].phase,{owned:'private_output',paid:'paid_receipt',scope:'fresh_scope'}[fault]);if(fault!=='scope')assert(!state.events.includes('probe'));}
});
Deno.test('non200status is observable but never interpreted as permission to regenerate',async()=>{
 for(const status of[401,403,409,429,500]){reset();state.response={status,value:{error:'TOKEN https://private.invalid'}};await run();assertEquals(state.fail,[]);assertEquals(state.rpcs.map((r:any)=>r.name),['property_video_job_poll_release']);assertEquals(state.diagnostics[0].phase,'status_response');assertEquals(state.diagnostics[0].http_status,status);assertEquals(state.methods,['GET']);assert(!JSON.stringify(state.diagnostics).includes('TOKEN'));}
 reset();state.response.value.status='processing';await run();assertEquals(state.diagnostics,[]);assertEquals(state.methods,['GET']);
});
Deno.test('closed poll telemetry ignores arbitrary error names URLs bodies and customer IDs',()=>{
 const error=new Error('SECRET https://private.invalid?credential=do-not-log');error.name='PRIVATE-CUSTOMER-AND-TOKEN';assertEquals(propertyVideoPollDiagnostic('clip_bytes',error),{event:'property_video_poll_failure',phase:'clip_bytes',error_name:'Other',http_status:null});
});
