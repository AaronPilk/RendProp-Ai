// Actual handler; only Auth/PostgREST are closed transports. No Apple purchase,
// pinned-root override, provider request or hosted mutation is performed here.
import {assert,assertEquals} from 'https://deno.land/std@0.224.0/assert/mod.ts';
const actor='e3000000-0000-4000-8000-000000000001',org='e3000000-0000-4000-8000-000000000002',listing='e3000000-0000-4000-8000-000000000003';
for(const[k,v]of Object.entries({SUPABASE_URL:'https://website-handler.fixture.invalid',SUPABASE_SERVICE_ROLE_KEY:'inert-fixture',SUPABASE_ANON_KEY:'inert-public'}))Deno.env.set(k,v);
let handler!:(req:Request)=>Promise<Response>;const old=Object.getOwnPropertyDescriptor(Deno,'serve')!;Object.defineProperty(Deno,'serve',{configurable:true,value:(h:typeof handler)=>{handler=h;return{};}});try{await import('./index.ts');}finally{Object.defineProperty(Deno,'serve',old);}
async function invoke(method:string,body?:unknown,options:{org?:string;guest?:boolean;deleting?:boolean;noAuth?:boolean}={}){
 const previous=globalThis.fetch,calls:Record<string,unknown>[]=[];
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init),url=new URL(req.url);assertEquals(url.hostname,'website-handler.fixture.invalid');
 if(url.pathname==='/auth/v1/user')return Response.json({id:actor,is_anonymous:options.guest===true});
 if(url.pathname.endsWith('/deletion_requests'))return Response.json(options.deleting?{id:actor}:null);
 if(url.pathname.includes('/rpc/')){const args=await req.json(),name=url.pathname.split('/').at(-1)!;calls.push({name,args});assert(['property_website_state','set_property_website_theme'].includes(name));return Response.json({listing_id:listing,org_id:org,website_theme:name==='set_property_website_theme'?args.p_theme:'basic',premium_website:{unlocked:false,purchase_enabled:false}});}
 throw Error('Unexpected closed request '+url.pathname);};
 try{const headers:Record<string,string>={'content-type':'application/json','x-org-id':options.org??org};if(!options.noAuth)headers.authorization='Bearer inert-fixture-token';const response=await handler(new Request(`https://app.fixture.invalid/property-sites/${listing}${method==='POST'?'/upgrade':''}`,{method,headers,...(body===undefined?{}:{body:JSON.stringify(body)})}));return{status:response.status,cache:response.headers.get('cache-control'),body:await response.json(),calls};}finally{globalThis.fetch=previous;}
}
Deno.test('actual website state and theme routes bind authenticated actor/property/workspace and are no-store',async()=>{
 const r=await invoke('GET');assertEquals(r.status,200);assertEquals(r.cache,'no-store');assertEquals(r.calls,[{name:'property_website_state',args:{p_actor:actor,p_listing:listing,p_expected_org:org}}]);assertEquals(r.body.premium_website.purchase_enabled,false);
 const changed=await invoke('PATCH',{website_theme:'basic',expected_org_id:org});assertEquals(changed.status,200);assertEquals(changed.calls[0],{name:'set_property_website_theme',args:{p_actor:actor,p_listing:listing,p_expected_org:org,p_theme:'basic'}});
});
Deno.test('stale workspace,deleted account,unsupported theme and oversized JWS refuse before entitlement writes',async()=>{
 for(const[body,options,status]of [[{website_theme:'basic',expected_org_id:listing},{},409],[{website_theme:'basic',expected_org_id:org},{deleting:true},409],[{website_theme:'invented',expected_org_id:org},{},400]]as const){const r=await invoke('PATCH',body,options);assertEquals(r.status,status);assertEquals(r.calls.length,0);}
 const large=await invoke('POST',{expected_org_id:org,signed_transaction:'x'.repeat(64*1024+1)});assertEquals(large.status,400);assertEquals(large.calls.length,0);
});
Deno.test('unsigned/untrusted Apple envelope and missing Auth can never grant a property upgrade',async()=>{
 const invalid=await invoke('POST',{expected_org_id:org,signed_transaction:'unsigned.claim.signature'});assertEquals(invalid.status,401);assertEquals(invalid.calls.length,0);
 const missing=await invoke('GET',undefined,{noAuth:true});assertEquals(missing.status,401);assertEquals(missing.calls.length,0);
});
