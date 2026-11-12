import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import { leadLibraryScope, listLibraryLeads, libraryListingIds } from "./library-leads.ts";
import { libraryProvenance, libraryUsageSummary } from "./library-summary.ts";

const owner="ab200109-0000-4000-8000-000000000001",sally="ab200109-0000-4000-8000-000000000002",tom="ab200109-0000-4000-8000-000000000003";
const team="ab200109-0000-4000-8000-000000000004",sallyOrg="ab200109-0000-4000-8000-000000000005",tomOrg="ab200109-0000-4000-8000-000000000006";
const listing="ab200109-0000-4000-8000-000000000007",lead="ab200109-0000-4000-8000-000000000008",provenance="ab200109-0000-4000-8000-000000000009";
function fixture() {
  let live=true, removed=false;
  let change=(name:string,data:any)=>data;
  const calls:{name:string;args:Record<string,unknown>}[]=[];
  const access=(actor:string,org:string)=>{
    const own=actor===sally&&org===sallyOrg,delegated=live&&actor===owner&&org===sallyOrg;
    if(!own&&!delegated)return null;
    return {actor_id:actor,org_id:org,library_owner_user_id:sally,role:delegated?"team_owner":"owner",access_mode:delegated?"team_owner":"own",
      can_read:true,can_write:true,can_manage_subscription:false,billing_org_id:removed?sallyOrg:team,team_org_id:removed?null:team};
  };
  const scope=(actor:string)=>{const a=access(actor,sallyOrg);return a?{...a,org_id:team,listing_id:listing,library_org_id:sallyOrg,listing_owner_user_id:sally}:null;};
  const admin={rpc:async(name:string,args:Record<string,unknown>)=>{
    calls.push({name,args});const actor=String(args.p_actor),org=String(args.p_org);let data:any;
    if(name==="library_access")data=access(actor,org);
    else if(name==="listing_library_scope")data=args.p_listing===listing?scope(actor):null;
    else if(name==="lead_library_scope")data=args.p_lead===lead&&scope(actor)?{...scope(actor),lead_id:lead}:null;
    else if(name==="list_library_leads")data=access(actor,org)?[{id:lead,listing_id:listing,org_id:team,library_org_id:sallyOrg,name:"Synthetic inquiry"}]:null;
    else if(name==="library_listing_ids")data=[listing];
    else if(name==="library_usage_summary")data={actor_id:actor,org_id:org,billing_org_id:removed?sallyOrg:team,listings:1,leads:1,leads_new:1,render_count:removed?0:7,cost_cents:removed?0:"15.25"};
    else if(name==="list_library_provenance")data=[{id:provenance,org_id:team,library_org_id:sallyOrg,listing_id:listing,original_key:`renders/${team}/${listing}/original.jpg`}];
    else throw Error("Unknown RPC "+name);
    if(data===null)return {data:null,error:{message:"RP404: Current content is unavailable"}};
    return {data:change(name,data),error:null};
  }};
  return {admin,calls,revoke:()=>{live=false;},remove:()=>{live=false;removed=true;},change:(fn:typeof change)=>{change=fn;}};
}
Deno.test("lead mutation retains physical org and logical library without sibling grants",async()=>{
  const f=fixture();assertEquals((await leadLibraryScope(f.admin,sally,lead,sallyOrg,true)).org_id,team);
  assertEquals((await leadLibraryScope(f.admin,owner,lead,sallyOrg,true)).library_org_id,sallyOrg);
  await assertRejects(()=>leadLibraryScope(f.admin,tom,lead,tomOrg,true),HttpError);
  await assertRejects(()=>leadLibraryScope(f.admin,sally,lead,tomOrg,true),HttpError);
  f.remove();await assertRejects(()=>leadLibraryScope(f.admin,owner,lead,sallyOrg,true),HttpError);
  assertEquals((await leadLibraryScope(f.admin,sally,lead,sallyOrg,true)).billing_org_id,sallyOrg);
});
Deno.test("lead scope refuses substituted actor, listing and physical org identities",async()=>{
  for(const patch of [{actor_id:tom},{listing_id:"bad"},{org_id:tomOrg},{library_org_id:tomOrg}]) {
    const f=fixture();f.change((name,data)=>name==="lead_library_scope"?{...data,...patch}:data);
    await assertRejects(()=>leadLibraryScope(f.admin,sally,lead,sallyOrg,true),HttpError);
  }
});
Deno.test("logical lead inbox returns legacy rows and refuses revoked or foreign rows",async()=>{
  const options={limit:100,since:null,status:null,listing:null};
  const f=fixture();const rows=await listLibraryLeads(f.admin,sally,sallyOrg,options);assertEquals(rows[0].org_id,team);
  const revoked=fixture();revoked.change((name,data)=>{if(name==="list_library_leads")revoked.revoke();return data;});
  await assertRejects(()=>listLibraryLeads(revoked.admin,owner,sallyOrg,options),HttpError);
  for(const patch of [{library_org_id:tomOrg},{id:"bad"},{listing_id:"bad"}]){const g=fixture();g.change((name,data)=>name==="list_library_leads"?[{...data[0],...patch}]:data);await assertRejects(()=>listLibraryLeads(g.admin,sally,sallyOrg,options),HttpError);}
});
Deno.test("compliance export scope includes page501 and rejects duplicate or malformed IDs",async()=>{
  const f=fixture(),ids=Array.from({length:501},(_,i)=>`ab210109-0000-4000-8000-${String(i).padStart(12,"0")}`);
  f.change((name,data)=>name==="library_listing_ids"?ids:data);assertEquals((await libraryListingIds(f.admin,sally,sallyOrg)).length,501);
  for(const data of [[listing,listing],["bad"]]){const g=fixture();g.change((name,value)=>name==="library_listing_ids"?data:value);await assertRejects(()=>libraryListingIds(g.admin,sally,sallyOrg),HttpError);}
});
Deno.test("serving summary binds selected content and pooled immutable billing identity",async()=>{
  const f=fixture(),summary=await libraryUsageSummary(f.admin,sally,sallyOrg,"2026-10-01T00:00:00Z");
  assertEquals(summary,{actor_id:sally,org_id:sallyOrg,billing_org_id:team,listings:1,leads:1,leads_new:1,render_count:7,cost_cents:15.25});
  for(const patch of [{actor_id:tom},{org_id:tomOrg},{billing_org_id:sallyOrg},{render_count:-1},{cost_cents:"NaN"}]){const g=fixture();g.change((name,data)=>name==="library_usage_summary"?{...data,...patch}:data);await assertRejects(()=>libraryUsageSummary(g.admin,sally,sallyOrg,"2026-10-01T00:00:00Z"),HttpError);}
});
Deno.test("compliance preserves physical keys and refuses mismatched listing/library media",async()=>{
  const options={from:null,to:null,listing:null,limit:100};
  const f=fixture(),rows=await libraryProvenance(f.admin,owner,sallyOrg,options);assertEquals(rows[0].org_id,team);assert(String(rows[0].original_key).includes(team));
  for(const patch of [{org_id:tomOrg},{library_org_id:tomOrg},{listing_id:lead}]){const g=fixture();g.change((name,data)=>name==="list_library_provenance"?[{...data[0],...patch}]:data);await assertRejects(()=>libraryProvenance(g.admin,sally,sallyOrg,options),HttpError);}
  const revoked=fixture();revoked.change((name,data)=>{if(name==="list_library_provenance")revoked.revoke();return data;});await assertRejects(()=>libraryProvenance(revoked.admin,owner,sallyOrg,options),HttpError);
});
