import { assert, assertEquals, assertRejects, AssertionError } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import { libraryAccess, libraryBillingOrg, listingLibraryScope, requireContentWrite } from "./library-access.ts";
import { listLibraryListings } from "./library-listings.ts";

const owner="ab100109-0000-4000-8000-000000000001",sally="ab100109-0000-4000-8000-000000000002",tom="ab100109-0000-4000-8000-000000000003";
const team="ab100109-0000-4000-8000-000000000004",sallyOrg="ab100109-0000-4000-8000-000000000005",tomOrg="ab100109-0000-4000-8000-000000000006";
const listing="ab100109-0000-4000-8000-000000000007";
function fixture() {
  let live=true; const calls:{name:string;args:Record<string,unknown>}[]=[];
  let mutate:(data:any,name:string)=>any=(data)=>data;
  const access=(actor:string,org:string) => {
    const own=(actor===sally&&org===sallyOrg)||(actor===tom&&org===tomOrg)||(actor===owner&&org===team);
    const delegated=live&&actor===owner&&[sallyOrg,tomOrg].includes(org);
    if(!own&&!delegated)return null;
    return {actor_id:actor,org_id:org,library_owner_user_id:org===team?owner:org===sallyOrg?sally:tom,
      role:delegated?"team_owner":"owner",access_mode:delegated?"team_owner":"own",can_read:true,can_write:true,
      can_manage_subscription:own&&org===team,billing_org_id:team,team_org_id:team};
  };
  const admin={rpc:async(name:string,args:Record<string,unknown>)=>{
    calls.push({name,args}); const actor=String(args.p_actor),org=String(args.p_org);let data:any;
    if(name==="library_billing_org")data=team;
    else if(name==="library_access")data=access(actor,org);
    else if(name==="listing_library_scope"){
      const allowed=args.p_listing===listing?access(actor,sallyOrg):null;
      data=allowed?{...allowed,org_id:team,listing_id:listing,library_org_id:sallyOrg,listing_owner_user_id:sally}:null;
      if(!data)return {data:null,error:{message:"RP404: Listing is not available"}};
    } else if(name==="list_library_listings"){
      const a=access(actor,org);if(!a)return {data:null,error:{message:"RP403: Removed seat"}};
      const rows=org===sallyOrg?[{id:listing,org_id:team,library_org_id:sallyOrg,agent_id:sally,deleted_at:null}]:[];
      data={actor_id:actor,org_id:org,listings:rows,total:rows.length,next_offset:null};
    } else throw Error("Unexpected authority RPC "+name);
    return {data:mutate(data,name),error:null};
  }};
  return {admin,calls,revoke:()=>{live=false;},mutate:(fn:typeof mutate)=>{mutate=fn;}};
}
for(const role of ["agent","admin","owner","marketing"])Deno.test(`membership role ${role} cannot grant Sally Tom's library`,async()=>{
  const f=fixture();f.mutate((data,name)=>name==="library_access"&&data?{...data,role}:data);
  const e=await assertRejects(()=>libraryAccess(f.admin,sally,tomOrg),HttpError);assertEquals(e.status,403);
  await assertRejects(()=>libraryAccess(f.admin,sally,team),HttpError);
  assertEquals(await libraryBillingOrg(f.admin,sallyOrg),team);
  await assertRejects(()=>libraryAccess(f.admin,sally,tomOrg),HttpError); // a billing root never grants content
});
Deno.test("actual Team owner can edit a bound private library without subscription authority",async()=>{
  const f=fixture(),a=await libraryAccess(f.admin,owner,sallyOrg);assertEquals(a.access_mode,"team_owner");assertEquals(a.can_manage_subscription,false);
  await requireContentWrite(f.admin,owner,team,listing);
  f.revoke();assertEquals((await assertRejects(()=>libraryAccess(f.admin,owner,sallyOrg),HttpError)).status,403);
  assertEquals((await assertRejects(()=>requireContentWrite(f.admin,owner,team,listing),HttpError)).status,404);
});
Deno.test("legacy listing exception authorizes the exact assigned row without broad old Team access",async()=>{
  const f=fixture(),a=await listingLibraryScope(f.admin,sally,listing,true);assertEquals(a.org_id,team);assertEquals(a.library_org_id,sallyOrg);
  await requireContentWrite(f.admin,sally,team,listing);
  await assertRejects(()=>requireContentWrite(f.admin,sally,tomOrg,listing),HttpError);
  await assertRejects(()=>requireContentWrite(f.admin,sally,team,null),HttpError);
  await assertRejects(()=>listingLibraryScope(f.admin,tom,listing,true),HttpError);
});
for(const change of [
  {actor_id:tom},{org_id:tomOrg},{library_owner_user_id:tom},{billing_org_id:"bad"},{team_org_id:"bad"},
  {access_mode:"team_owner",role:"admin"},{access_mode:"team_owner",role:"team_owner",can_manage_subscription:true},{can_read:false,can_write:true},
])Deno.test(`authority response binding refuses ${JSON.stringify(change)}`,async()=>{
  const f=fixture();f.mutate(data=>data?{...data,...change}:data);await assertRejects(()=>libraryAccess(f.admin,sally,sallyOrg),HttpError);
});
Deno.test("known revoked/access/deletion RPC errors retain status rather than becoming upstream outages",async()=>{
  for(const status of [401,403,404,409]){
    const admin={rpc:()=>Promise.resolve({data:null,error:{message:`RP${status}: Refused`}})};
    assertEquals((await assertRejects(()=>libraryAccess(admin,sally,sallyOrg),HttpError)).status,status);
  }
});
Deno.test("complete sync exposes authoritative legacy alias and rechecks owner binding after its page",async()=>{
  const f=fixture(),p=await listLibraryListings(f.admin,owner,sallyOrg,new URLSearchParams("library=1&limit=500&offset=0"));
  assertEquals(p.listings[0].org_id,team);assertEquals(p.listings[0].library_org_id,sallyOrg);
  assertEquals(f.calls.map(c=>c.name),["library_access","list_library_listings","library_access"]);
  const revoked=fixture();revoked.mutate((data,name)=>{if(name==="list_library_listings")revoked.revoke();return data;});
  await assertRejects(()=>listLibraryListings(revoked.admin,owner,sallyOrg,new URLSearchParams("library=1")),HttpError);
});
for(const change of [{actor_id:tom},{total:501,next_offset:null},{next_offset:1},{listings:[{id:listing,org_id:team,library_org_id:tomOrg,agent_id:tom,deleted_at:null}]}])Deno.test(`sync refuses incomplete or forged page ${JSON.stringify(change)}`,async()=>{
  const f=fixture();f.mutate((data,name)=>name==="list_library_listings"?{...data,...change}:data);
  await assertRejects(()=>listLibraryListings(f.admin,sally,sallyOrg,new URLSearchParams("library=1")),HttpError);
});
Deno.test("sync rejects unbounded and filtered requests before the authority call",async()=>{
  for(const params of ["limit=501","offset=-1","offset=100001","status=ready","limit=0","limit=1.5"]){const f=fixture();await assertRejects(()=>listLibraryListings(f.admin,sally,sallyOrg,new URLSearchParams(params)),HttpError);assertEquals(f.calls,[]);}
});
Deno.test("removed actor-binding guard negative control admits a response the real helper refuses",async()=>{
  const source=await Deno.readTextFile(new URL("./library-access.ts",import.meta.url));
  assert(source.includes("value.actor_id === actor && value.org_id === org"));
  const changed=source.replaceAll("./http.ts",new URL("./http.ts",import.meta.url).href).replaceAll("value.actor_id === actor && ","");
  const mutant=await import("data:application/typescript,"+encodeURIComponent(changed));
  const f=fixture();f.mutate(data=>data?{...data,actor_id:tom}:data);
  await assertRejects(()=>libraryAccess(f.admin,sally,sallyOrg),HttpError);
  assertEquals((await mutant.libraryAccess(f.admin,sally,sallyOrg)).actor_id,tom);
});

Deno.test("retained legacy financial scope follows the actor after Team removal; actor omission fails the same oracle",async()=>{
  const calls:{name:string,args:Record<string,unknown>}[]=[];
  const admin={rpc:async(name:string,args:Record<string,unknown>)=>{
    calls.push({name,args});
    if(name==="library_actor_billing_org"){
      assertEquals(args,{p_actor:sally,p_org:team});
      return {data:sallyOrg,error:null}; // the removed agent now funds her own library
    }
    assertEquals(name,"library_billing_org");assertEquals(args,{p_org:team});
    return {data:team,error:null}; // the physical legacy namespace still belongs to the old Team
  }};
  const oracle=async(fn:typeof libraryBillingOrg)=>assertEquals(await fn(admin,team,sally),sallyOrg);
  await oracle(libraryBillingOrg);
  assertEquals(calls[0],{name:"library_actor_billing_org",args:{p_actor:sally,p_org:team}});
  const source=await Deno.readTextFile(new URL("./library-access.ts",import.meta.url));
  const anchor='  assert(UUID.test(org), 400, "Choose a valid listing library.");';
  assert(source.includes(anchor));
  const mutant=await import("data:application/typescript,"+encodeURIComponent(source.replaceAll("./http.ts",new URL("./http.ts",import.meta.url).href)
    .replace(anchor,'  actor = undefined;\n'+anchor)));
  await assertRejects(()=>oracle(mutant.libraryBillingOrg),AssertionError);
  // The two feature counter callers must pass the verified actor too; the
  // financial helper cannot infer a person from an old physical org alone.
  for(const route of ["../ai-photo/index.ts","../ai-voice/index.ts"]){
    const caller=await Deno.readTextFile(new URL(route,import.meta.url));
    assert(caller.includes("libraryBillingOrg(adminClient(), orgId, user.id)"));
  }
});
