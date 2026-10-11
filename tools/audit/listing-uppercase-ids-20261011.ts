// Entire actual `listings` handler against a closed synthetic Auth/PostgREST
// transport, driven with the request shape the phone really sends: an
// UPPERCASE listing id in the URL path and an UPPERCASE org id in X-Org-Id.
//
// 2026-10-11 incident: TestFlight 57 showed "Needs attention — Listing identity
// returned inconsistent data." on every facts save, and the same 503 hit
// /me/compliance, /uploads and /ai-photo. `UUID.uuidString` is uppercase,
// Postgres renders uuid text lowercase, and the authority compare was `===`.
//
// Expectations:
//   * the RPC receives canonical lowercase ids (Postgres semantics either way,
//     but the handler must never forward a casing it then fails to compare);
//   * PUT /listings/<UPPER>/facts is 200, not 503;
//   * the negative control (the shared helper with canonicalisation removed)
//     reproduces the exact 503 + message the phone showed.
//
// Run: deno run --allow-env --allow-read tools/audit/listing-uppercase-ids-20261011.ts
const ORG='a0401011-0000-4000-8000-000000000001', ID='a0401011-0000-4000-8000-000000000002', USER='a0401011-0000-4000-8000-000000000003';
const UPPER_ID=ID.toUpperCase(), UPPER_ORG=ORG.toUpperCase();
for(const [k,v] of Object.entries({SUPABASE_URL:'https://facts-fixture.invalid',SUPABASE_ANON_KEY:'fixture-anon',SUPABASE_SERVICE_ROLE_KEY:'fixture-service',CLOUDFLARE_ACCOUNT_ID:'fixture',R2_ACCESS_KEY_ID:'fixture',R2_SECRET_ACCESS_KEY:'fixture',R2_BUCKET_RENDERS:'renders',R2_BUCKET_UPLOADS:'uploads',R2_PUBLIC_BASE_URL:'https://media.fixture.invalid'}))Deno.env.set(k,v);
let count=0; function check(ok:unknown,label:string){count++;if(!ok)throw new Error(label);}
function same(a:unknown,b:unknown,label:string){check(JSON.stringify(a)===JSON.stringify(b),label+' :: '+JSON.stringify(a)+' !== '+JSON.stringify(b));}
function response(value:unknown,status=200){return new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});}
type Handler=(req:Request)=>Promise<Response>;
let calls:{path:string,method:string,body:unknown}[]=[];
// Postgres uuid semantics: any casing in, canonical lowercase out.
const lower=(v:unknown)=>typeof v==='string'?v.toLowerCase():v;
globalThis.fetch=async(input,init)=>{
 const r=new Request(input,init),u=new URL(r.url);check(u.hostname==='facts-fixture.invalid','Transport stays on closed fixture origin');
 const body=r.method==='GET'?null:await r.json();calls.push({path:u.pathname,method:r.method,body});
 if(u.pathname==='/auth/v1/user')return response({id:USER,is_anonymous:false});
 if(u.pathname.endsWith('/rpc/workspace_directory')){
  check(body.p_preferred_org===undefined||body.p_preferred_org===null||lower(body.p_preferred_org)===ORG,'Workspace lookup carries the selected org');
  return response({actor_id:USER,own_org_id:ORG,billing_org_id:ORG,can_switch_agent_libraries:false,active_org_id:ORG,workspaces:[{id:ORG,name:'Fixture',role:'owner',access_mode:'own',library_owner_user_id:USER,billing_org_id:ORG,can_read:true,can_write:true,can_manage_subscription:true,team_org_id:null}]});
 }
 if(u.pathname.endsWith('/rpc/listing_library_scope')){
  // Postgres would accept either casing; the DB answers in lowercase regardless.
  check(lower(body.p_actor)===USER&&lower(body.p_listing)===ID,'Listing authority is bound to the actor and listing');
  return response({actor_id:USER,listing_id:ID,org_id:ORG,library_org_id:ORG,library_owner_user_id:USER,listing_owner_user_id:USER,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true,billing_org_id:ORG,team_org_id:null});
 }
 if(u.pathname==='/rest/v1/deletion_requests')return response(null);
 if(u.pathname.endsWith('/rpc/save_listing_facts'))return response({id:ID,org_id:ORG,address:'855 Central Ave',sqft:2345,beds:2,baths:2,status:'ready',details:{},lat:27.772,lng:-82.646,updated_at:'2026-10-11T15:00:00Z'});
 if(u.pathname==='/rest/v1/listings')return response({id:ID,org_id:ORG,main_photo_key:null,gallery_asset_ids:[]});
 throw new Error('Unmodeled transport '+r.method+' '+u.pathname);
};
async function loadHandler(entry:string):Promise<Handler>{
 let handler!:Handler;
 const serve=Object.getOwnPropertyDescriptor(Deno,'serve')!;
 try {Object.defineProperty(Deno,'serve',{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return{};}});await import(entry);}
 finally{Object.defineProperty(Deno,'serve',serve);}
 return handler;
}
const intent={expected:{lat:35.001,lng:-80.001},changes:{lat:27.772,lng:-82.646},details_expected:{},details_changes:{}};
async function invoke(handler:Handler,listingSegment:string,org:string){
 calls=[];
 const h:Record<string,string>={authorization:'Bearer fixture','content-type':'application/json','X-Org-Id':org};
 return await handler(new Request('https://edge.fixture.invalid/listings/'+listingSegment+'/facts',{method:'PUT',headers:h,body:JSON.stringify(intent)}));
}

// 1. The real handler with the phone's casing.
const real=await loadHandler('../../services/supabase/functions/listings/index.ts');
let r=await invoke(real,UPPER_ID,UPPER_ORG);
check(r.status===200,'Uppercase path id + uppercase X-Org-Id must save facts (got '+r.status+' '+await r.clone().text()+')');
const scopeCall=calls.find(x=>x.path.endsWith('/rpc/listing_library_scope'))!;
same(scopeCall.body,{p_actor:USER,p_listing:ID},'Authority RPC receives canonical lowercase ids');
const save=calls.find(x=>x.path.endsWith('/rpc/save_listing_facts'))!;
same([save.body.p_actor,save.body.p_org,save.body.p_listing],[USER,ORG,ID],'Facts RPC receives canonical lowercase ids');
r=await invoke(real,ID,ORG);check(r.status===200,'Lowercase ids still save');
r=await invoke(real,UPPER_ID.replace(/-/g,'_'),ORG);check(r.status===400,'A malformed id is still rejected as 400, not quietly lowercased into something else');

// 2. Negative control: the shared helper WITHOUT canonicalisation shows the
//    phone's exact failure, so this audit is tied to the real cause.
const sharedURL=new URL('../../services/supabase/functions/_shared/library-access.ts',import.meta.url);
const source=await Deno.readTextFile(sharedURL);
const anchor='function canonical(id: string): string { return id.toLowerCase(); }';
check(source.includes(anchor),'Canonicalisation helper present in library-access.ts');
const mutant=await import('data:application/typescript,'+encodeURIComponent(source.replaceAll('./http.ts',new URL('./http.ts',sharedURL).href).replace(anchor,'function canonical(id: string): string { return id; }')));
const admin={rpc:async(_name:string,args:Record<string,unknown>)=>({data:{actor_id:lower(args.p_actor),listing_id:lower(args.p_listing),org_id:ORG,library_org_id:ORG,billing_org_id:ORG,team_org_id:null,library_owner_user_id:USER,listing_owner_user_id:USER,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true},error:null})};
let refused:unknown=null;try{await mutant.listingLibraryScope(admin,USER,UPPER_ID,true);}catch(e){refused=e;}
check(refused!==null&&(refused as {status?:number}).status===503&&(refused as {message?:string}).message==='Listing identity returned inconsistent data.','Without canonicalisation the phone\'s exact 503 reproduces');
const fixed=await import(sharedURL.href);
check((await fixed.listingLibraryScope(admin,USER,UPPER_ID,true)).listing_id===ID,'With canonicalisation the same call succeeds');
console.log(JSON.stringify({passed:true,assertions:count,scope:'Actual listings handler with uppercase phone ids; closed synthetic transport; negative control reproduces the 2026-10-11 503'}));
