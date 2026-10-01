import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
const USER="d0100105-0000-4000-8000-000000000001",A="d0100105-0000-4000-8000-000000000002",B="d0100105-0000-4000-8000-000000000003",OUTSIDER="d0100105-0000-4000-8000-000000000004";
const ROW_A="d0100105-0000-4000-8000-000000000005",ROW_B="d0100105-0000-4000-8000-000000000006";
type Handler=(req:Request)=>Promise<Response>;
const handlers:Record<string,Handler>={};
async function fixture(run:(f:{call:(app:string,method:string,path:string,body?:unknown,org?:string,key?:string)=>Promise<{status:number;body:any}>;active:()=>string;setActive:(id:string)=>void;revoke:(id:string)=>void;calls:{path:string;body:any;url:URL}[];fail:(message:string)=>void})=>Promise<void>){
 const values={SUPABASE_URL:"https://workspace-fixture.invalid",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",SUPABASE_ANON_KEY:"fixture-anon"};
 const previous=new Map(Object.keys(values).map(k=>[k,Deno.env.get(k)]));for(const[k,v]of Object.entries(values))Deno.env.set(k,v);
 const oldFetch=globalThis.fetch,serve=Object.getOwnPropertyDescriptor(Deno,"serve")!;
 const calls:{path:string;body:any;url:URL}[]=[],unexpected:string[]=[];
 let active=A,error:string|undefined;
 const workspaces=[{id:A,name:"Personal",role:"owner"},{id:B,name:"Agency",role:"agent"}];
 const rows=[{id:ROW_A,org_id:A,address:"Personal home",deleted_at:null},{id:ROW_B,org_id:B,address:"Agency home",deleted_at:null}];
 const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json"}});
 try{
  globalThis.fetch=async(input,init)=>{
   const req=new Request(input,init),url=new URL(req.url);let body:any=null;if(req.body)body=await req.json();calls.push({path:url.pathname,body,url});
   if(url.hostname!=="workspace-fixture.invalid"){unexpected.push(req.url);throw new Error("Unmodeled network denied");}
   const table=url.pathname.split("/").pop();
   if(url.pathname==="/auth/v1/user")return json({id:USER,aud:"authenticated",is_anonymous:false});
   if(table==="workspace_directory"){
    assertEquals(body.p_user,USER);if(error)return json({message:error},400);
    const selected=body.p_preferred_org??active;
    if(!workspaces.some(w=>w.id===selected))return json({message:"RP403: this workspace is no longer available"},400);
    return json({active_org_id:selected,workspaces});
   }
   if(table==="select_workspace"){
    assertEquals(body.p_user,USER);if(error)return json({message:error},400);
    const selected=workspaces.find(w=>w.id===body.p_org);if(!selected)return json({message:"RP403: this workspace is no longer available"},400);
    active=selected.id;return json({ok:true,org_id:active,org_name:selected.name,role:selected.role});
   }
   if(table==="deletion_requests")return json([]);
   if(table==="active_org_for_user")return json(active);
   if(table==="listings"){
    if(req.method==="POST"){const row={...body,id:body.id??crypto.randomUUID(),deleted_at:null};if(rows.some(r=>r.id===row.id))return json({code:"23505",message:"duplicate fixture"},409);rows.push(row);return json(row,201);}
    let selected=rows.filter(r=>r.deleted_at===null);
    for(const key of ["id","org_id"]){const filter=url.searchParams.get(key);if(filter?.startsWith("eq."))selected=selected.filter(r=>r[key as "id"|"org_id"]===filter.slice(3));}
    if(req.method==="PATCH"){for(const row of selected)Object.assign(row,body);}
    return json(req.headers.get("accept")?.includes("vnd.pgrst.object")?(selected[0]??null):selected);
   }
   unexpected.push(url.pathname);throw new Error("Unmodeled request");
  };
  for(const app of ["me","listings"]){
   Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:Handler)=>{handlers[app]=fn;return {};}});
   if(app==="me")await import("./index.ts");else await import("../listings/index.ts");
  }
  const call=async(app:string,method:string,path:string,body?:unknown,org?:string,key?:string)=>{
   const headers:Record<string,string>={authorization:"Bearer fixture-session"};if(body!==undefined)headers["content-type"]="application/json";if(org!==undefined)headers["x-org-id"]=org;if(key!==undefined)headers["idempotency-key"]=key;
   const result=await handlers[app](new Request(`https://edge.invalid/${app}${path}`,{method,headers,...(body===undefined?{}:{body:JSON.stringify(body)})}));
   return {status:result.status,body:await result.json()};
  };
  await run({call,active:()=>active,setActive:id=>{active=id;},revoke:id=>{const at=workspaces.findIndex(w=>w.id===id);if(at>=0)workspaces.splice(at,1);},calls,fail:message=>{error=message;}});
  assertEquals(unexpected,[]);
 }finally{globalThis.fetch=oldFetch;Object.defineProperty(Deno,"serve",serve);for(const[k,v]of previous)v===undefined?Deno.env.delete(k):Deno.env.set(k,v);}
}
Deno.test("workspace directory keeps personal and shared memberships visible",()=>fixture(async f=>{
 const r=await f.call("me","GET","/workspaces");assertEquals(r.status,200);assertEquals(r.body.active_org_id,A);assertEquals(r.body.workspaces.map((w:any)=>w.id),[A,B]);
}));
Deno.test("workspace selection uses verified caller and preserves requested role",()=>fixture(async f=>{
 const r=await f.call("me","POST","/workspace",{org_id:B,user_id:OUTSIDER,role:"owner"},A);
 assertEquals(r.status,200);assertEquals(r.body,{ok:true,org_id:B,org_name:"Agency",role:"agent"});assertEquals(f.active(),B);
 assertEquals((await f.call("me","GET","/workspaces",undefined,A)).body.active_org_id,A);
}));
Deno.test("invalid selection and malformed explicit headers never fall back",()=>fixture(async f=>{
 for(const org_id of [null,"",42,"bad"]){assertEquals((await f.call("me","POST","/workspace",{org_id})).status,400);}
 for(const app of ["me","listings"]){assertEquals((await f.call(app,"GET",app==="me"?"/workspaces":"",undefined,"")).status,400);}
 assertEquals(f.active(),A);assertEquals(f.calls.filter(c=>c.path.endsWith("select_workspace")).length,0);
}));
Deno.test("forbidden, deleted or removed workspace cannot be selected or read",()=>fixture(async f=>{
 assertEquals((await f.call("me","POST","/workspace",{org_id:OUTSIDER})).status,403);
 f.revoke(B);
 for(const [app,path]of [["me","/workspaces"],["listings",""]])assertEquals((await f.call(app,"GET",path,undefined,B)).status,403);
 assertEquals((await f.call("me","POST","/workspace",{org_id:B})).status,403);assertEquals(f.active(),A);
}));
Deno.test("selection and directory failure is recoverable with no success response",()=>fixture(async f=>{
 f.fail("temporary database outage");for(const [method,path,body]of [["GET","/workspaces",undefined],["POST","/workspace",{org_id:B}]]as const){const r=await f.call("me",method,path,body);assertEquals(r.status,503);assert(!r.body.ok);}assertEquals(f.active(),A);
}));
Deno.test("legacy listing snapshot stays complete; explicit workspace filters without deleting personal work",()=>fixture(async f=>{
 f.setActive(B);const all=await f.call("listings","GET","");assertEquals(all.status,200);assertEquals(all.body.map((r:any)=>r.id),[ROW_A,ROW_B]);
 const one=await f.call("listings","GET","",undefined,A);assertEquals(one.status,200);assertEquals(one.body.map((r:any)=>r.id),[ROW_A]);
 assertEquals((await f.call("listings","GET","")).body.length,2);
}));
Deno.test("bound listing create and retry cannot follow another device's active switch",()=>fixture(async f=>{
 const key="listing-create:d0100105-0000-4000-8000-000000000099";
 const first=await f.call("listings","POST","",{address:"Started in A",org_id:B,agent_id:OUTSIDER},A,key);
 assertEquals(first.status,201);assertEquals(first.body.org_id,A);assertEquals(first.body.agent_id,USER);
 // Ignore the first response as if it was lost, then another device switches.
 f.setActive(B);const retry=await f.call("listings","POST","",{address:"Stale retry"},A,key);
 assertEquals(retry.status,200);assertEquals(retry.body.id,first.body.id);assertEquals(retry.body.org_id,A);assertEquals(retry.body.address,"Started in A");assertEquals(retry.body.create_replayed,true);
 assertEquals((await f.call("listings","GET","")).body.length,3);
 assertEquals(f.calls.filter(c=>c.path.endsWith("active_org_for_user")).length,0);
}));
Deno.test("bound listing edits and deletion refuse IDs from another selected workspace",()=>fixture(async f=>{
 assertEquals((await f.call("listings","PATCH","/"+ROW_B,{address:"Wrong workspace"},A)).status,404);
 assertEquals((await f.call("listings","DELETE","/"+ROW_B,undefined,A)).status,404);
 assertEquals((await f.call("listings","PATCH","/"+ROW_A,{address:"Correct workspace"},A)).status,200);
 assertEquals((await f.call("listings","GET","",undefined,B)).body[0].address,"Agency home");
}));
Deno.test("legacy listing create retains its existing active-workspace default",()=>fixture(async f=>{
 f.setActive(B);const r=await f.call("listings","POST","",{address:"Legacy"});assertEquals(r.status,201);assertEquals(r.body.org_id,B);
}));
