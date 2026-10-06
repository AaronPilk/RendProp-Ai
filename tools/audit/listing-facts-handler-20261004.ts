// Entire actual handler against a closed synthetic Auth/PostgREST transport.
// This proves routing and intent forwarding, not PostgreSQL CAS/RLS behavior.
const ORG='a0400405-0000-4000-8000-000000000001', ID='a0400405-0000-4000-8000-000000000002', USER='a0400405-0000-4000-8000-000000000003';
for(const [k,v] of Object.entries({SUPABASE_URL:'https://facts-fixture.invalid',SUPABASE_ANON_KEY:'fixture-anon',SUPABASE_SERVICE_ROLE_KEY:'fixture-service',CLOUDFLARE_ACCOUNT_ID:'fixture',R2_ACCESS_KEY_ID:'fixture',R2_SECRET_ACCESS_KEY:'fixture',R2_PUBLIC_BASE_URL:'https://cover.fixture.invalid'})) Deno.env.set(k,v);
let count=0; function check(ok:unknown,label:string){count++;if(!ok)throw new Error(label);}
function same(a:unknown,b:unknown,label:string){check(JSON.stringify(a)===JSON.stringify(b),label);}
function response(value:unknown,status=200){return new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});}
type Handler=(req:Request)=>Promise<Response>; let handler!:Handler;
let rpcError:string|undefined,deleting=false,calls:{path:string,method:string,body:unknown}[]=[];
globalThis.fetch=async(input,init)=>{
 const r=new Request(input,init),u=new URL(r.url);check(u.hostname==='facts-fixture.invalid','Transport stays on closed fixture origin');
 const body=r.method==='GET'?null:await r.json();calls.push({path:u.pathname,method:r.method,body});
 if(u.pathname==='/auth/v1/user')return response({id:USER,is_anonymous:false});
 if(u.pathname.endsWith('/rpc/workspace_directory'))return response({active_org_id:ORG,workspaces:[{id:ORG,name:'Fixture',role:'owner'}]});
 if(u.pathname==='/rest/v1/deletion_requests')return response(deleting?{status:'pending'}:null);
 if(u.pathname.endsWith('/rpc/save_listing_facts'))return rpcError?response({code:rpcError,message:'fixture refusal'},rpcError==='PT409'?409:400):response({id:ID,org_id:ORG,address:'Shared',sqft:2345,status:'archived',details:{floorplan_asset_id:'preserved'}});
 if(u.pathname==='/rest/v1/listings')return response({id:ID,org_id:ORG,main_photo_key:null,gallery_asset_ids:[]});
 throw new Error('Unmodeled transport '+r.method+' '+u.pathname);
};
const serve=Object.getOwnPropertyDescriptor(Deno,'serve')!;
try {Object.defineProperty(Deno,'serve',{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return{};}});await import('../../services/supabase/functions/listings/index.ts');}
finally{Object.defineProperty(Deno,'serve',serve);}
const intent={expected:{lat:35.001,lng:-80.001},changes:{lat:35.235,lng:-80.346},details_expected:{},details_changes:{}};
async function invoke(method:string,body:unknown,suffix='/facts',workspace=true){calls=[];const h:Record<string,string>={authorization:'Bearer fixture','content-type':'application/json'};if(workspace)h['X-Org-Id']=ORG;return await handler(new Request('https://edge.fixture.invalid/listings/'+ID+suffix,{method,headers:h,body:JSON.stringify(body)}));}
let r=await invoke('PUT',intent);check(r.status===200,'Explicit intent succeeds');
const rpc=calls.find(x=>x.path.endsWith('/rpc/save_listing_facts'))!;
same(rpc.body,{p_actor:USER,p_org:ORG,p_listing:ID,p_expected:intent.expected,p_changes:intent.changes,p_details_expected:{},p_details_changes:{}},'Actual handler forwards exact intent and authenticated scope');
check(!calls.some(x=>x.path==='/rest/v1/listings'&&x.method==='PATCH'),'Facts never use broad table PATCH');
for(const [code,status]of [['PT409',409],['40001',409],['42501',403],['P0002',404],['22023',400]]as const){rpcError=code;r=await invoke('PUT',intent);check(r.status===status,'Maps SQL refusal '+code);check(calls.filter(x=>x.path.endsWith('/rpc/save_listing_facts')).length===1,'Exactly one RPC on refusal '+code);}
rpcError=undefined;
r=await invoke('PUT',intent,'/facts',false);check(r.status===409,'Facts require explicitly selected workspace');check(!calls.some(x=>x.path.endsWith('/rpc/save_listing_facts')),'No RPC without workspace');
for(const bad of [{...intent,details:{}},{...intent,expected:null},{...intent,changes:{address:123}}]){r=await invoke('PUT',bad);check(r.status===400,'Invalid or extra intent rejected');check(!calls.some(x=>x.path.endsWith('/rpc/save_listing_facts')),'Invalid intent does not reach RPC');}
r=await invoke('PATCH',{address:'Stale',sqft:900,status:'ready',details:{old:'value'}},'');check(r.status===426,'Legacy broad writes require upgrade');check(!calls.some(x=>x.path==='/rest/v1/listings'&&x.method==='PATCH'),'Legacy write never updates shared facts');
r=await invoke('PATCH',{main_photo_key:null},'');check(r.status===200,'Dedicated photo update remains compatible');
same(calls.find(x=>x.path==='/rest/v1/listings'&&x.method==='PATCH')?.body,{main_photo_key:null},'Photo update never includes ordinary facts');
r=await invoke('PUT',{expected:{status:'archived'},changes:{status:'ready'},details_expected:{},details_changes:{}});check(r.status===200,'Studio status intent uses same route');
deleting=true;r=await invoke('PUT',intent);check(r.status===409,'Deletion gate blocks intent');check(!calls.some(x=>x.path.endsWith('/rpc/save_listing_facts')),'Deletion prevents RPC');
console.log(JSON.stringify({passed:true,assertions:count,scope:'Actual full handler; closed synthetic transport; real SQL/RLS tested separately'}));
