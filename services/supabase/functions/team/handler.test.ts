// Run the deployed handler with mocked Auth/PostgREST transport. No sockets,
// provider calls, notification draining or real email addresses are involved.
import { assert, assertEquals, assertMatch } from "https://deno.land/std@0.224.0/assert/mod.ts";
type Row = Record<string, unknown>;
type Handler = (req: Request) => Promise<Response>;
const user = "d0100101-0000-4000-8000-000000000001";
const org = "d0100101-0000-4000-8000-000000000002";
const invite = "d0100101-0000-4000-8000-000000000003";
const personal = "d0100101-0000-4000-8000-000000000005";
let handler: Handler;
class Fixture {
  role = "owner";
  masterTesting = false;
  privateRoster: unknown[] = [];
  testingContext: unknown = null;
  failedRPC: string | null = null;
  accepted: unknown = { org_id: org, org_name: "Fixture Team", role: "agent" };
  anonymous = false;
  pausedSeat = false;
  failureTable: string | null = null;
  roster: {user_id: string; org_id: string; role: string}[] | null = null;
  rosterProfiles: {id: string; name: string; email: string}[] = [];
  failProfileUser: string | null = null;
  profileReads: {target: string; targetBytes: number; ids: string[]; ok: boolean}[] = [];
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
      if (table === "org_seats_used") return json(this.pausedSeat ? 5 : this.roster?.length ?? 1);
      if (table === "org_seats_allowed") return json(this.pausedSeat ? 3 : this.roster?.length ?? 2);
      const body = await req.json();
      if (this.failedRPC === table) return json({message:"fixture unavailable"},503);
      if (table === "workspace_directory") return json({actor_id:user,own_org_id:this.pausedSeat ? personal : org,billing_org_id:this.pausedSeat ? personal : org,can_switch_agent_libraries:false,active_org_id:this.pausedSeat ? personal : org,workspaces:[{id:this.pausedSeat ? personal : org,name:"Fixture Team",role:"owner",access_mode:"own",library_owner_user_id:user,billing_org_id:this.pausedSeat ? personal : org,can_read:true,can_write:true}]});
      if (table === "library_access") return json({actor_id:user,org_id:this.pausedSeat ? personal : org,library_owner_user_id:user,role:this.role,access_mode:"own",can_read:true,can_write:this.role!=="marketing",can_manage_subscription:!this.testingContext,billing_org_id:this.pausedSeat ? personal : org,team_org_id:null});
      if (table === "paused_team_org") { assertEquals(body,{p_actor:user}); return json(this.pausedSeat ? org : null); }
      if (table === "team_seat_status") {
        assertEquals(body,{p_org:org});
        return json(this.roster?.map(member => ({user_id:member.user_id,seat_active:true})) ??
          [{user_id:user,seat_active:!this.pausedSeat}]);
      }
      if (table === "org_has_internal_testing_grant") return json(this.masterTesting);
      if (table === "private_internal_testing_host_mode") return json(this.masterTesting ? {configured:true,active:true,access_mode:"private_testing"} : null);
      if (table === "private_internal_testing_context") {
        assertEquals(body.p_user,user);
        assert([org,personal].includes(body.p_private_org));
        return json(this.testingContext);
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
      if (this.roster) {
        assertEquals(url.searchParams.get("org_id"),"eq."+org);
        const actorFilter = url.searchParams.get("user_id");
        assert(actorFilter === null || actorFilter === "eq."+user);
        return json(this.roster.filter(member => actorFilter === null || member.user_id === user));
      }
      return json([{user_id:user,org_id:org,role:this.role}]);
    }
    if (this.failureTable === table) return json({message:"unavailable"},503);
    if (table === "profiles") {
      if (!this.roster) return json([{id:user,name:"Fixture Manager",email:"manager@fixture.invalid"}]);
      // Enforce a realistic gateway request-target limit on the actual URL
      // serialized by supabase-js, not on a duplicated chunk-size constant.
      const target = url.pathname + url.search;
      const targetBytes = new TextEncoder().encode(target).byteLength;
      const filter = url.searchParams.get("id");
      assertMatch(filter ?? "", /^in\.\([a-f0-9,-]+\)$/);
      const ids = filter!.slice(4,-1).split(",");
      assertEquals(new Set(ids).size,ids.length);
      const known = new Map(this.rosterProfiles.map(profile => [profile.id,profile]));
      assert(ids.every(id => known.has(id)),"Profile lookup must stay inside the fixture's exact roster");
      const ok = targetBytes <= 8192 && !ids.includes(this.failProfileUser ?? "");
      this.profileReads.push({target,targetBytes,ids,ok});
      if (targetBytes > 8192) return json({message:"fixture request target exceeds 8KiB"},414);
      if (!ok) return json({message:"later fixture profile chunk unavailable"},503);
      // PostgREST need not return the same order as the membership rows.
      // Reversal catches an implementation that zips rows instead of joining ids.
      return json([...ids].reverse().map(id => known.get(id)!));
    }
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
Deno.test("downgraded member can read paused Team seat without regaining manager access",async()=>fixture(async f=>{
  f.pausedSeat=true; f.role="agent";
  const response=await f.request("",{},"GET"); const body=await response.json();
  assertEquals(response.status,200);
  assertEquals(body.content_org_id,personal);
  assertEquals(body.org_id,org);
  assertEquals(body.can_manage,false);
  assertEquals(body.seats,{used:5,allowed:3,paused:1});
  assertEquals(body.members.length,1);
  assertEquals(body.members[0].seat_active,false);
  assertEquals(body.invites,[]);
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
 f.anonymous=true;f.failedRPC="private_internal_testing_host_mode";const response=await f.request("",{},"GET");const body=await response.json();assertEquals(response.status,200);assertEquals(body.access_mode,"private_libraries");assertEquals(body.members.length,1);assertEquals(f.writes,[]);
}));


function configureFirmRoster(f: Fixture) {
  const members = Array.from({length:500},(_,index) => ({
    user_id:index === 0 ? user : `d0148500-0000-4000-8000-${String(index).padStart(12,"0")}`,
    org_id:org,
    role:index === 0 ? "owner" : index % 7 === 0 ? "marketing" : "agent",
  }));
  const profiles = members.map((member,index) => ({id:member.user_id,
    name:`Fixture member ${index}`,email:`member-${index}@fixture.invalid`}));
  f.roster = members; f.rosterProfiles = profiles;
  return {members,profiles};
}

Deno.test("500-member team read preserves every profile mapping within gateway request-target bounds",async()=>fixture(async f=>{
  const {members,profiles} = configureFirmRoster(f);
  const response = await f.request("",{},"GET");
  assertEquals(response.status,200);
  const body = await response.json();
  assertEquals(body.actor_id,user);assertEquals(body.org_id,org);assertEquals(body.content_org_id,org);
  assertEquals(body.can_manage,true);assertEquals(body.invites,[]);
  assertEquals(body.seats,{used:500,allowed:500,paused:0});
  assertEquals(body.members,members.map((member,index) => ({
    user_id:member.user_id,role:member.role,name:profiles[index]!.name,email:profiles[index]!.email,
    is_you:member.user_id === user,seat_active:true,
  })),"All 500 ids, roles, names and emails must survive the real handler's merge");
  assertEquals(new Set(body.members.map((member:Row) => member.user_id)).size,500);
  assert(f.profileReads.length > 0);
  assert(f.profileReads.every(read => read.ok && read.targetBytes <= 8192),
    "Every serialized profile request target must fit the gateway, including URL encoding");
  assertEquals([...new Set(f.profileReads.flatMap(read => read.ids))].sort(),
    members.map(member => member.user_id).sort(),"No profile may be omitted or looked up outside the roster");
  assertEquals(f.writes,[]);assertEquals(f.queueCalls,0);
}));

Deno.test("later profile chunk failure refuses the whole 500-member team read without a partial roster",async()=>fixture(async f=>{
  const {members} = configureFirmRoster(f);
  f.failProfileUser = members.at(-1)!.user_id;
  const response = await f.request("",{},"GET");
  assertEquals(response.status,503);
  const body = await response.json();
  assert(!("members" in body),"Successful earlier chunks cannot become a partial-success roster");
  const failedIndex = f.profileReads.findIndex(read => read.ids.includes(f.failProfileUser!));
  assert(failedIndex > 0 && f.profileReads.slice(0,failedIndex).some(read => read.ok && read.ids.length > 0),
    "The control must reach a later chunk after an earlier chunk actually returned profiles");
  assertEquals(f.profileReads[failedIndex]!.ok,false);
  assert(f.profileReads.every(read => read.targetBytes <= 8192),
    "The intended later-chunk failure must not be an unrelated oversized-URL refusal");
  assertEquals(f.writes,[]);assertEquals(f.queueCalls,0);
}));
