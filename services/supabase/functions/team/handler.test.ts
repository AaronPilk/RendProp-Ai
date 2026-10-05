// Run the deployed handler with mocked Auth/PostgREST transport. No sockets,
// provider calls, notification draining or real email addresses are involved.
import { assert, assertEquals, assertMatch } from "https://deno.land/std@0.224.0/assert/mod.ts";
type Row = Record<string, unknown>;
type Handler = (req: Request) => Promise<Response>;
const user = "d0100101-0000-4000-8000-000000000001";
const org = "d0100101-0000-4000-8000-000000000002";
const invite = "d0100101-0000-4000-8000-000000000003";
let handler: Handler;
class Fixture {
  role = "owner";
  masterTesting = false;
  privateRoster: unknown[] = [];
  testingContext: unknown = null;
  failedRPC: string | null = null;
  accepted: unknown = { org_id: org, org_name: "Fixture Team", role: "agent" };
  anonymous = false;
  failureTable: string | null = null;
  queueResults: unknown[] = [{ ok: true, queued: true, id: invite }];
  queueCalls = 0;
  writes: string[] = [];
  unexpected: string[] = [];
  logs: string[] = [];
  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const req = new Request(input, init), url = new URL(req.url);
    const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {status, headers: {"content-type":"application/json"}});
    const row = (data: unknown) => json(req.headers.get("accept")?.includes("vnd.pgrst.object") ? data : [data]);
    if (url.hostname !== "team-fixture.invalid") { this.unexpected.push(req.url); throw new Error("External network refused"); }
    if (url.pathname === "/auth/v1/user") return json({id:user,aud:"authenticated",is_anonymous:this.anonymous});
    const table = url.pathname.split("/").pop()!;
    if (url.pathname.startsWith("/rest/v1/rpc/")) {
      if (table === "bump_rate") return json(true);
      if (table === "active_org_for_user") return json(org);
      if (table === "org_seats_used") return json(1);
      if (table === "org_seats_allowed") return json(2);
      const body = await req.json();
      if (this.failedRPC === table) return json({message:"fixture unavailable"},503);
      if (table === "org_has_internal_testing_grant") return json(this.masterTesting);
      if (table === "private_internal_testing_host_mode") return json(this.masterTesting ? {configured:true,active:true,access_mode:"private_testing"} : null);
      if (table === "private_internal_testing_context") {
        assertEquals(body,{p_user:user,p_private_org:org}); return json(this.testingContext);
      }
      if (table === "private_internal_testing_members") {
        assertEquals(body,{p_actor:user,p_sponsor_org:org}); return json(this.privateRoster);
      }
      this.writes.push(table);
      if (table === "accept_org_invite") {
        assertEquals(body.p_user,user);assertMatch(body.p_token_hash,/^[a-f0-9]{64}$/);assertEquals(Object.keys(body).sort(),["p_token_hash","p_user"]);
        return json(this.accepted);
      }
      if (table === "remove_private_internal_tester") {
        assertEquals(body,{p_actor:user,p_sponsor_org:org,p_beneficiary:"d0100101-0000-4000-8000-000000000004"});
        return json({ok:true,removed:true,private_testing:true});
      }
      if (table === "create_org_invite") {
        assertEquals(body.p_user,user); assertEquals(body.p_org,org);
        assertMatch(body.p_token_hash,/^[a-f0-9]{64}$/);
        return json({id:invite,email:body.p_email,role:body.p_role});
      }
      if (table === "create_org_invites_bulk") return json({issued:2,results:[
        {id:invite,email:"one@fixture.invalid",code:"ABCD-EFGH-JKMN",outcome:"issued"},
        {id:crypto.randomUUID(),email:"two@fixture.invalid",code:"PQRS-TVWX-YZ23",outcome:"issued"},
        {email:"bad",outcome:"invalid"}]});
      if (table === "notification_enqueue_invite") {
        assertEquals(body.p_org,org); assertEquals(body.p_inviter,user);
        assert(typeof body.p_code === "string");
        const result = this.queueCalls < this.queueResults.length ? this.queueResults[this.queueCalls++] : (this.queueCalls++, {ok:true,queued:true});
        if (result === "transport-error") return json({message:"database rejected SECRET-CODE"},503);
        return json(result);
      }
      this.unexpected.push(table); throw new Error("Unexpected RPC");
    }
    if (table === "memberships") {
      if (url.searchParams.get("select") === "role") return row({role:this.role});
      if (this.failureTable === table) return json({message:"unavailable"},503);
      return json([{user_id:user,org_id:org,role:this.role}]);
    }
    if (this.failureTable === table) return json({message:"unavailable"},503);
    if (table === "profiles") return json([{id:user,name:"Fixture Manager",email:"manager@fixture.invalid"}]);
    if (table === "org_invites") return json([]);
    if (table === "orgs") return row({name:"Fixture Team",plan:"team"});
    this.unexpected.push(table); throw new Error("Unexpected table");
  };
  async request(path = "invites", body: Row = {email:"invite@fixture.invalid"}, method = "POST") {
    return await handler(new Request(`https://edge.invalid/team${path ? "/"+path : ""}`, {
      method, headers:{authorization:"Bearer fixture-token","content-type":"application/json"},
      ...(method === "GET" ? {} : {body:JSON.stringify(body)})
    }));
  }
}
async function fixture(run:(f:Fixture)=>Promise<void>) {
  const f = new Fixture();
  const values = {SUPABASE_URL:"https://team-fixture.invalid",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",SUPABASE_ANON_KEY:"fixture-anon"};
  const previous = new Map(Object.keys(values).map(key=>[key,Deno.env.get(key)]));
  for (const [key,value] of Object.entries(values)) Deno.env.set(key,value);
  const fetch = globalThis.fetch, serve = Object.getOwnPropertyDescriptor(Deno,"serve")!, log = console.error;
  try {
    globalThis.fetch = f.fetch;
    console.error = (...args:unknown[]) => f.logs.push(args.join(" "));
    Object.defineProperty(Deno,"serve",{configurable:true,writable:true,value:(fn:Handler)=>{handler=fn;return {};}});
    await import("./index.ts"); assert(handler);
    await run(f); assertEquals(f.unexpected,[]);
  } finally {
    globalThis.fetch = fetch; console.error = log; Object.defineProperty(Deno,"serve",serve);
    for (const [key,value] of previous) value === undefined ? Deno.env.delete(key) : Deno.env.set(key,value);
  }
}
for (const failed of [{ok:false,reason:'42703: column "full_name" does not exist'},"transport-error",null]) {
  Deno.test(`valid invite code survives enqueue failure with truthful status: ${JSON.stringify(failed)}`,async()=>fixture(async f=>{
    f.queueResults = [failed];
    const response = await f.request(); assertEquals(response.status,201);
    const result = await response.json(); assertMatch(result.code,/^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    assertEquals(result.emailed,false); assertEquals(result.email_queued,false);
    assertEquals(f.queueCalls,1); assertEquals(f.logs,["invite mail not queued"]);
  }));
}
Deno.test("single invite confirms queued, not delivered, and keeps deduplication acknowledgement",async()=>fixture(async f=>{
  f.queueResults = [{ok:true,queued:true},{ok:true,queued:false,reason:"already_queued"}];
  for (let i=0;i<2;i++) { const response=await f.request(); const result=await response.json(); assertEquals(response.status,201);assertEquals(result.email_queued,true);assertEquals(result.emailed,true); }
}));
Deno.test("code-only invitation does not claim or enqueue email",async()=>fixture(async f=>{
  const response=await f.request("invites",{}); const result=await response.json();
  assertEquals(response.status,201);assertEquals(result.email_queued,false);assertEquals(result.emailed,false);assertEquals(f.queueCalls,0);
}));
Deno.test("bulk invitation counts only confirmed outbox submissions and preserves every code",async()=>fixture(async f=>{
  f.queueResults = [{ok:false,reason:"fixture"},{ok:true,queued:true}];
  const response=await f.request("invites/bulk",{emails:["one@fixture.invalid","two@fixture.invalid","bad"]});const result=await response.json();
  assertEquals(response.status,201);assertEquals(result.issued,2);assertEquals(result.emails_queued,1);assertEquals(result.results.filter((r:Row)=>r.code).length,2);
}));
for (const failureTable of ["memberships","profiles","org_invites","orgs"]) {
  Deno.test(`team read refuses false empty success when ${failureTable} fails`,async()=>fixture(async f=>{
    f.failureTable=failureTable;const response=await f.request("",{},"GET");assertEquals(response.status,503);
    const result=await response.json();assert(!("members" in result));assertEquals(f.writes,[]);
  }));
}
Deno.test("ordinary team member cannot issue invites or see pending invite details",async()=>fixture(async f=>{
  f.role="agent";const denied=await f.request();assertEquals(denied.status,403);assertEquals(f.writes,[]);
  f.failureTable="org_invites";const read=await f.request("",{},"GET");assertEquals(read.status,200);const result=await read.json();assertEquals(result.can_manage,false);assertEquals(result.invites,[]);
}));
Deno.test("anonymous workspace owner cannot invite a team",async()=>fixture(async f=>{
  f.anonymous=true;const denied=await f.request();assertEquals(denied.status,403);assertEquals(f.writes,[]);
}));

const privatePerson={user_id:"d0100101-0000-4000-8000-000000000004",role:"agent",name:"Fixture tester",email:"tester@fixture.invalid",private_testing:true,benefits_active:true,joined_at:"2026-10-05T00:00:00Z"};
Deno.test("private tester roster is included without content membership or listing queries",async()=>fixture(async f=>{
 f.masterTesting=true;f.privateRoster=[privatePerson];const response=await f.request("",{},"GET");const body=await response.json();
 assertEquals(response.status,200);assertEquals(body.access_mode,"private_testing");assertEquals(body.members.length,2);
 assertEquals(body.members[1],{user_id:privatePerson.user_id,role:"agent",name:privatePerson.name,email:privatePerson.email,is_you:false,access_mode:"private_testing",benefits_active:true});assertEquals(f.writes,[]);
}));
Deno.test("private join selects the caller's existing workspace and accepts no beneficiary override",async()=>fixture(async f=>{
 const privateOrg="d0100101-0000-4000-8000-000000000005";
 f.accepted={org_id:privateOrg,org_name:"Fixture private workspace",role:"owner",private_testing:true,team_name:"Fixture testing team"};
 const response=await f.request("accept",{code:"ABCD-EFGH-JKMN",beneficiary_user_id:privatePerson.user_id,private_org_id:org});const body=await response.json();
 assertEquals(response.status,200);assertEquals(body,{ok:true,org_id:privateOrg,org_name:"Fixture private workspace",role:"owner",access_mode:"private_testing",team_name:"Fixture testing team"});assertEquals(f.writes,["accept_org_invite"]);
}));
Deno.test("private tester removal uses the sponsorship RPC without deleting membership or projects",async()=>fixture(async f=>{
 f.privateRoster=[privatePerson];const response=await f.request("members/"+privatePerson.user_id,{},"DELETE");assertEquals(response.status,200);assertEquals(await response.json(),{ok:true,private_testing:true});assertEquals(f.writes,["remove_private_internal_tester"]);
}));
Deno.test("private member still cannot administer the sponsor's tester roster",async()=>fixture(async f=>{
 f.role="agent";f.privateRoster=[privatePerson];const response=await f.request("members/"+privatePerson.user_id,{},"DELETE");assertEquals(response.status,403);assertEquals(f.writes,[]);
}));
for(const failedRPC of ["private_internal_testing_members","private_internal_testing_host_mode","private_internal_testing_context"])Deno.test(`private roster fails closed when ${failedRPC} cannot be verified`,async()=>fixture(async f=>{
 f.failedRPC=failedRPC;const response=await f.request("",{},"GET");assertEquals(response.status,503);assert(!("members"in await response.json()));assertEquals(f.writes,[]);
}));
Deno.test("sponsored private workspace reports Team benefits without becoming a manager of the sponsor",async()=>fixture(async f=>{
 f.testingContext={active:true,sponsor_org_id:"d0100101-0000-4000-8000-000000000009",sponsor_org_name:"Fixture testing team",private_org_id:org,beneficiary_user_id:user,plan:"team",source:"manual",unmetered_business_allowances:true};
 const response=await f.request("",{},"GET");const body=await response.json();assertEquals(response.status,200);assertEquals(body.can_manage,false);assertEquals(body.access_mode,"private_testing");assertEquals(body.team_name,"Fixture testing team");assertEquals(body.org_id,org);assertEquals(body.members.length,1);
}));

Deno.test("ordinary anonymous owner can still read its own workspace without private-host authority",async()=>fixture(async f=>{
 f.anonymous=true;f.failedRPC="private_internal_testing_host_mode";const response=await f.request("",{},"GET");const body=await response.json();assertEquals(response.status,200);assertEquals(body.access_mode,"shared_workspace");assertEquals(body.members.length,1);assertEquals(f.writes,[]);
}));
