import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// Execute the complete current handler plus its real input/output sanitizers.
// Only Auth, workspace/plan/meter/ledger and provider boundaries are doubles.
const SELECTED_ORG = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb";
const ACTIVE_ORG = "bbbbbbbb-1111-2222-3333-cccccccccccc";

async function fixture(bypassMembership = false, dropPreference = false) {
  let source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  source = source.replace(/^import [\s\S]*?;\n/gm, "");
  source = source.replace(
    "Deno.serve(async (req) => {",
    "export const handler = async (req: Request) => {",
  );
  assert(source.endsWith("});\n"));
  source = source.slice(0, -4) + "};\n";
  const membershipCall = "await orgForUser(user.id, requestedOrg)";
  assert(source.includes(membershipCall));
  if (bypassMembership) {
    source = source.replace(membershipCall, JSON.stringify(SELECTED_ORG));
  }
  if (dropPreference) {
    source = source.replace(membershipCall, "await orgForUser(user.id)");
  }
  const shared = await Deno.readTextFile(
    new URL("../_shared/supabase.ts", import.meta.url),
  );
  const orgStart = shared.indexOf("export async function orgForUser(");
  const orgEnd = shared.indexOf("/** Resolve one authorized listing", orgStart);
  const headerStart = shared.indexOf("export function preferredOrg(", orgEnd);
  const headerEnd = shared.indexOf("\n}\n", headerStart) + 3;
  assert(
    orgStart >= 0 && orgEnd > orgStart && headerStart > orgEnd &&
      headerEnd > headerStart,
  );
  const actualMembership = shared.slice(orgStart, orgEnd).replace(
    "export async",
    "async",
  );
  const actualHeader = shared.slice(headerStart, headerEnd).replace(
    "export function",
    "function",
  );
  const code = `
    import {HttpError,assert,json,pathSegments,readJsonLimited,respondError} from ${
    JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
  };
    import {handleOptions} from ${
    JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)
  };
    import {buildUserTurn,screenOf,spaceTypeOf,systemInstruction} from ${
    JSON.stringify(new URL("./prompt.ts", import.meta.url).href)
  };
    import {workspaceDirectory} from ${JSON.stringify(new URL("../_shared/workspaces.ts",import.meta.url).href)};
    import {coachContext} from ${JSON.stringify(new URL("./context.ts", import.meta.url).href)};
    import {fundingContext,fundedAttempt,textAttemptQuote,completeFundingOperation} from ${JSON.stringify(new URL("../_shared/funded-serving.ts",import.meta.url).href)};
    import {parseCoachOutput} from ${
    JSON.stringify(new URL("./actions.ts", import.meta.url).href)
  };
    type RouteStep=any;type CoachContext=any;type CoachListingCtx=any;type Entitlement=any;
    export const state:any={options:{},providers:0,ledgers:0,ledgerRows:[],orgLookups:[],meters:[],plans:[],events:[],contextQueries:[],counts:new Map()};
    export function reset(options:any={}){Object.assign(state,{options,providers:0,ledgers:0,ledgerRows:[],orgLookups:[],meters:[],plans:[],events:[],contextQueries:[],counts:new Map()});}
    const getUser=async(req:Request)=>({id:req.headers.get("x-test-user")??"c0300501-0000-4000-8000-000000000001",is_anonymous:false});
    const ROLE_RANK={owner:0,admin:1,agent:2,marketing:3};
    function query(table:string){
      const filters:any={};let columns="",head=false;
      const result=()=>{
        const admission=table==="memberships"&&columns==="org_id";
        if(admission){state.events.push("org");state.orgLookups.push({table,...filters});return {error:null,data:!state.options.noOrg&&[${JSON.stringify(SELECTED_ORG)},${JSON.stringify(ACTIVE_ORG)}].includes(filters.org_id)?{org_id:filters.org_id}:null};}
        state.contextQueries.push({table,columns,filters:{...filters},head});
        if(state.options.contextError===table)return {data:null,count:null,error:{message:"synthetic private SQL failure"}};
        if(table==="orgs")return {error:null,data:state.options.noOrg?null:{plan_source:"apple",plan_expires_at:"2028-01-01T00:00:00Z",deleted_at:null}};
        if(table==="memberships")return {error:null,data:state.options.noOrg||state.options.removedAfterAdmission?null:{role:state.options.role??"owner"}};
        if(table==="listings")return head?{error:null,count:3}: {error:null,data:(state.options.listingRows??[]).filter((r:any)=>(!filters.org_id||r.org_id===filters.org_id)&&r.deleted_at==null&&filters.id?.includes(r.id))};
        if(table==="leads")return {error:null,count:2};
        if(table==="render_jobs")return {error:null,count:4};
        if(table==="rate_limits")return {error:null,data:state.options.meterRows??[]};
        if(table==="apple_subscriptions")return {error:null,data:{status:"active",auto_renew:false,expires_at:"2028-01-01T00:00:00Z"}};
        throw Error("Unexpected context table "+table);
      };
      return {select(c:string,o:any={}){columns=c;head=o.head===true;return this;},eq(k:string,v:any){filters[k]=v;return this;},is(k:string,v:any){filters[k]=v;return this;},in(k:string,v:any){filters[k]=v;return this;},gte(k:string,v:any){filters[k]=v;return this;},limit(n:number){filters.limit=n;return this;},order(k:string,v:any){filters.order={k,...v};return this;},async maybeSingle(){return result();},then(resolve:any,reject:any){return Promise.resolve().then(result).then(resolve,reject);}};
    }
    const adminClient=()=>({from:query,rpc:async(name:string,args:any)=>{
      if(name==="serving_operation_begin")return {data:{begun:true},error:null};
      if(name==="serving_cost_reserve")return {data:{reserved:true},error:null};
      if(name==="serving_cost_finish")return {data:{finished:true},error:null};
      if(name==="serving_operation_complete")return {data:{saved:true},error:null};
      if(name==="workspace_directory"){
       state.events.push("org");state.orgLookups.push({name,args});
       if(state.options.noOrg||!state.options.noOrg&&args.p_preferred_org&&![${JSON.stringify(SELECTED_ORG)},${JSON.stringify(ACTIVE_ORG)}].includes(args.p_preferred_org))return {data:null,error:{message:"RP403: Current library unavailable"}};
       const org=args.p_preferred_org??${JSON.stringify(ACTIVE_ORG)};
       return {data:{actor_id:args.p_user,own_org_id:org,billing_org_id:org,can_switch_agent_libraries:false,active_org_id:org,workspaces:[{id:org,name:"Synthetic library",role:state.options.role??"owner",access_mode:"own",library_owner_user_id:args.p_user,billing_org_id:org,can_read:true,can_write:true}]},error:null};
      }
      if(name==="library_access"){
       if(state.options.noOrg||state.options.removedAfterAdmission)return {data:null,error:{message:"RP403: Revoked library"}};
       return {data:{actor_id:args.p_actor,org_id:args.p_org,library_owner_user_id:args.p_actor,role:state.options.role??"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:state.options.role!=="agent",billing_org_id:args.p_org,team_org_id:null},error:null};
      }
      if(name==="listing_library_scope"){
       const row=(state.options.listingRows??[]).find((r:any)=>r.id===args.p_listing&&r.org_id===${JSON.stringify(SELECTED_ORG)}&&r.deleted_at==null);
       if(!row)return {data:null,error:{message:"RP404: Listing unavailable"}};
       return {data:{actor_id:args.p_actor,org_id:row.org_id,listing_id:row.id,library_org_id:row.org_id,library_owner_user_id:args.p_actor,listing_owner_user_id:args.p_actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true,billing_org_id:row.org_id,team_org_id:null},error:null};
      }
      if(name==="library_usage_summary")return state.options.contextError==="leads"?{data:null,error:{message:"Synthetic summary failed"}}:{data:{actor_id:args.p_actor,org_id:args.p_org,billing_org_id:args.p_org,listings:3,leads:2,leads_new:2,render_count:4,cost_cents:0},error:null};
      throw Error("Unmodeled context RPC "+name);}});
    const userClient=(_req:Request)=>({from:query});
    ${actualHeader}
    ${actualMembership}
    const assertPaidAiIdentity=async(..._a:any[])=>{state.events.push("identity");if(state.options.identityDenied)throw new HttpError(401,"Sign in required");};
    const entitlementFor=async(..._a:any[])=>{state.events.push("plan");if(state.options.planError)throw Error("Synthetic plan outage");return {plan:state.options.plan??"team",degraded:state.options.degraded??false,renders_per_month:8,photo_edits_per_month:50,reels_per_month:10,aerials_per_month:4,topaz_per_month:0};};
    const durableRateLimit=async(key:string,max:number,seconds:number)=>{state.meters.push({key,max,seconds});const n=state.counts.get(key)??0;if(n>=max)return false;state.counts.set(key,n+1);return true;};
    const resolveRoute=async(_task:any,context:any)=>{state.plans.push(context.plan);return [];};
    const runChain=async(_task:any,steps:any[],callback:any)=>({value:await callback(steps[0]),step:steps[0]});
    const anthropicMessages=async(args:any)=>{state.events.push("provider");state.providers++;if(state.options.providerError)throw new HttpError(502,"synthetic provider credential/private prompt");state.maxTokens=args.maxTokens;state.system=args.system;state.userTurn=args.content[0].text;return JSON.stringify({reply:"Start with a clear photo of each room.",actions:[],suggested_replies:[]});};
    const openaiChat=anthropicMessages;
    class ProviderError extends Error{}
    const recordRoutedAiCost=async(...args:any[])=>{state.events.push("ledger");state.ledgers++;state.ledgerRows.push(args[1]);return {recorded:true};};
    ${source}
  `;
  return await import(
    `data:application/typescript;base64,${
      btoa(String.fromCharCode(...new TextEncoder().encode(code)))
    }`
  );
}

function req(
  user = "c0300501-0000-4000-8000-000000000001",
  plan = "brokerage",
  org: string | null = SELECTED_ORG,
  extras: Record<string, unknown> = {},
) {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-test-user": user,
  };
  if (org !== null) headers["X-Org-Id"] = org;
  // Auth uses real UUID identities; symbolic fixture seats map deterministically.
  if(!/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(user)) {let n=0;for(const c of user)n=(n*31+c.charCodeAt(0))>>>0;user=`c0300501-0000-4000-8000-${String(n).padStart(12,"0")}`;}
  headers["x-test-user"]=user;
  return new Request("https://fixture.invalid/coach", {
    method: "POST",
    headers,
    body: JSON.stringify({
      messages: [{ role: "user", content: "Help me get started" }],
      context: { plan },
      ...extras,
    }),
  });
}

async function assertNoOrgDenied(f: Awaited<ReturnType<typeof fixture>>) {
  f.reset({ noOrg: true });
  assertEquals((await f.handler(req())).status, 403);
  assertEquals(f.state.providers, 0);
  assertEquals(f.state.ledgers, 0);
  assertEquals(f.state.meters.length, 0);
}

Deno.test("actual coach denies missing membership/identity before meters and paid work", async () => {
  const f = await fixture();
  await assertNoOrgDenied(f);
  for (const options of [{ noOrg: true }, { identityDenied: true }]) {
    f.reset(options);
    const response = await f.handler(req());
    assertEquals(response.status, options.noOrg ? 403 : 401);
    assertEquals(f.state.providers, 0);
    assertEquals(f.state.ledgers, 0);
    assertEquals(f.state.meters.length, 0);
  }
});

Deno.test("actual coach uses trusted plan and routes a degraded lookup as free", async () => {
  const f = await fixture();
  for (
    const [options, expected] of [[{ plan: "starter" }, "starter"], [{
      plan: "team",
      degraded: true,
    }, "free"], [{ planError: true }, "free"]] as const
  ) {
    f.reset(options);
    assertEquals(
      (await f.handler(req("c0300501-0000-4000-8000-000000000001", "brokerage"))).status,
      200,
    );
    assertEquals(f.state.plans, [expected]);
    assertEquals(f.state.providers, 1);
    assertEquals(f.state.ledgers, 1);
    assertEquals(f.state.maxTokens, 600);
    assertEquals(f.state.events.slice(0, 3), ["org", "identity", "plan"]);
    assertEquals(f.state.meters[2], {
      key: `coachorgday:${SELECTED_ORG}`,
      max: 600,
      seconds: 86400,
    });
  }
});

Deno.test("actual coach workspace safety cap bounds distinct seats while retaining per-user limits", async () => {
  const f = await fixture();
  f.reset();
  for (let i = 0; i < 600; i++) {
    // Respect the existing burst (12) and day (60) limits: fifty distinct seats.
    assertEquals(
      (await f.handler(req(`synthetic-seat-${Math.floor(i / 12)}`))).status,
      200,
    );
  }
  const denied = await f.handler(req("synthetic-new-seat"));
  assertEquals(denied.status, 429);
  assertEquals(f.state.providers, 600);
  assertEquals(f.state.ledgers, 600);
  const body = await denied.json();
  assert(body.error.includes("workspace"));
});

Deno.test("Coach context authority recheck still denies paid work when initial admission is bypassed", async () => {
  const mutant = await fixture(true);
  await assertNoOrgDenied(mutant);
  assertEquals(mutant.state.providers, 0);
});

async function assertSelectedWorkspace(f: Awaited<ReturnType<typeof fixture>>) {
  f.reset();
  assertEquals(
    (await f.handler(
      req("c0300501-0000-4000-8000-000000000001", "brokerage", SELECTED_ORG.toUpperCase()),
    )).status,
    200,
  );
  assertEquals(f.state.orgLookups, [{
    name: "workspace_directory",
    args: {p_user: "c0300501-0000-4000-8000-000000000001",p_preferred_org: SELECTED_ORG},
  }]);
  assertEquals(f.state.meters[2].key, `coachorgday:${SELECTED_ORG}`);
  assertEquals(f.state.ledgerRows[0].orgId, SELECTED_ORG);
}

Deno.test("actual Coach header/membership bodies meter and ledger the selected workspace, not the active one", async () => {
  await assertSelectedWorkspace(await fixture());
});

Deno.test("actual Coach rejects missing, malformed and foreign workspace before any meter/provider/ledger", async () => {
  const f = await fixture();
  for (
    const [org, status] of [[null, 409], ["not-a-workspace", 400], [
      "cccccccc-1111-2222-3333-dddddddddddd",
      403,
    ]] as const
  ) {
    f.reset();
    assertEquals(
      (await f.handler(req("c0300501-0000-4000-8000-000000000001", "team", org))).status,
      status,
    );
    assertEquals(f.state.providers, 0);
    assertEquals(f.state.ledgers, 0);
    assertEquals(f.state.meters.length, 0);
  }
});

Deno.test("Coach selected-workspace negative control proves ignoring the header bills the different active workspace", async () => {
  const mutant = await fixture(false, true);
  await assertRejects(() => assertSelectedWorkspace(mutant));
  assertEquals(mutant.state.providers, 1);
  assertEquals(mutant.state.ledgerRows[0].orgId, ACTIVE_ORG);
});

Deno.test("all native screen and industry raw values reach the actual Coach prompt; arbitrary screen text cannot reach ledger", async () => {
  const askSource = await Deno.readTextFile(
    new URL(
      "../../../../apps/ios/Rendprop/Coach/AskAIButton.swift",
      import.meta.url,
    ),
  );
  const screenEnum = askSource.slice(
    askSource.indexOf("enum AskAIScreen: String"),
    askSource.indexOf("    /// Four questions"),
  );
  const nativeScreens = Array.from(
    screenEnum.matchAll(/^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?\s*$/gm),
    (match) => match[2] ?? match[1],
  );
  assertEquals(nativeScreens.length, 14);
  const listingSource = await Deno.readTextFile(
    new URL(
      "../../../../apps/ios/Rendprop/Models/Listing.swift",
      import.meta.url,
    ),
  );
  const industryStart = listingSource.indexOf("enum SpaceType: String");
  const industryEnum = listingSource.slice(
    industryStart,
    listingSource.indexOf("    var id:", industryStart),
  );
  const nativeIndustries = Array.from(
    industryEnum.matchAll(/^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?\s*$/gm),
    (match) => match[2] ?? match[1],
  );
  assertEquals(nativeIndustries, [
    "real_estate",
    "venue",
    "restaurant",
    "retail",
    "fitness",
    "other",
  ]);
  const f = await fixture();
  for (const screen of nativeScreens) {
    f.reset();
    assertEquals(
      (await f.handler(
        req("c0300501-0000-4000-8000-000000000001", "team", SELECTED_ORG, { context: { screen } }),
      )).status,
      200,
    );
    assertEquals(f.state.ledgerRows[0].meta.screen, screen);
    assert(f.state.userTurn.includes(`currently on the "${screen}" screen`));
  }
  for (const space of nativeIndustries) {
    f.reset();
    assertEquals(
      (await f.handler(
        req("c0300501-0000-4000-8000-000000000001", "team", SELECTED_ORG, { space_type: space }),
      )).status,
      200,
    );
    assert(f.state.system.includes(`industry: ${space}`));
  }
  for (
    const screen of ["123 Synthetic Address", "photo_studio\nsecret", {
      home: true,
    }, 42]
  ) {
    f.reset();
    assertEquals(
      (await f.handler(
        req("c0300501-0000-4000-8000-000000000001", "team", SELECTED_ORG, { context: { screen } }),
      )).status,
      200,
    );
    assertEquals(f.state.ledgerRows[0].meta.screen, null);
    assert(!f.state.userTurn.includes("123 Synthetic Address"));
  }
});

Deno.test("actual Coach verifies local-to-cloud project mapping and drops foreign/deleted context before prompting", async () => {
  const f = await fixture();
  const local = "c0100501-0000-4000-8000-000000000001", cloud = "c0100501-0000-4000-8000-000000000002", foreign = "c0100501-0000-4000-8000-000000000003";
  f.reset({listingRows:[{id:cloud,org_id:SELECTED_ORG,deleted_at:null,status:"processing"},{id:foreign,org_id:ACTIVE_ORG,deleted_at:null,status:"ready"}]});
  assertEquals((await f.handler(req("c0300501-0000-4000-8000-000000000001","brokerage",SELECTED_ORG,{context:{selected_listing_id:local,listings:[{id:local,server_id:cloud,title:"Owned Street",attention:"render"},{id:foreign,title:"Foreign private street",attention:"private SQL error"}]}}))).status,200);
  assert(f.state.userTurn.includes(`Selected project id: ${local}`));
  assert(f.state.userTurn.includes("server_status=processing"));
  assert(f.state.userTurn.includes("device_attention=render"));
  assert(!f.state.userTurn.includes("Foreign private street"));
  assert(!f.state.userTurn.includes("private SQL error"));
  const lookup=f.state.contextQueries.find((q:any)=>q.table==="listings"&&!q.head);
  assertEquals(lookup.filters.org_id,undefined);
  assertEquals(lookup.filters.deleted_at,null);
  assertEquals(lookup.filters.id,[cloud]);
  assertEquals(lookup.filters.limit,25);
  assertEquals(f.state.ledgerRows[0].meta.listing_count,1);
});

Deno.test("actual Coach uses only bounded real selected-workspace account/usage facts and marks degraded plan unknown", async () => {
  const f=await fixture();
  f.reset({role:"agent",meterRows:[{key:`aiphotomo:${SELECTED_ORG}`,count:72,window_start:new Date().toISOString(),window_seconds:2592000}]});
  assertEquals((await f.handler(req())).status,200);
  const snapshot=JSON.parse(f.state.userTurn.split("\n").find((line:string)=>line.startsWith("Verified selected-workspace"))!.split(": ").slice(1).join(": "));
  assertEquals(snapshot.role,"agent");assertEquals(snapshot.can_manage_subscription,false);
  assertEquals(snapshot.renewal,"off");assertEquals(snapshot.subscription_status,"active");
  assertEquals(snapshot.projects,3);assertEquals(snapshot.new_leads,2);
  assertEquals(snapshot.usage.renders.used,4);assertEquals(snapshot.usage.renders.cap,8);
  assertEquals(snapshot.usage.photo_edits.used,50);assertEquals(snapshot.usage.photo_edits.cap,50);
  assert(f.state.contextQueries.every((q:any)=>!/(email|address|brand_kit|phone|original_transaction|error|total_cents)/.test(q.columns)));
  for(const query of f.state.contextQueries.filter((q:any)=>["orgs","memberships","leads","apple_subscriptions"].includes(q.table)))assertEquals(query.filters[query.table==="orgs"?"id":"org_id"],SELECTED_ORG);
  f.reset({degraded:true,contextError:"leads"});assertEquals((await f.handler(req())).status,200);
  const unavailable=JSON.parse(f.state.userTurn.split("\n").find((line:string)=>line.startsWith("Verified selected-workspace"))!.split(": ").slice(1).join(": "));
  assertEquals(unavailable.available,false);assertEquals(unavailable.usage.renders.cap,null);assertEquals(unavailable.new_leads,null);
  assertEquals(unavailable.renewal,"unknown");assertEquals(unavailable.can_manage_subscription,false);
});

Deno.test("actual Coach rechecks lost workspace authority before metering and safely hides upstream errors", async () => {
  const f=await fixture();f.reset({removedAfterAdmission:true});
  assertEquals((await f.handler(req())).status,403);assertEquals(f.state.providers,0);assertEquals(f.state.meters,[]);
  f.reset({contextError:"orgs"});const denied=await f.handler(req());assertEquals(denied.status,503);
  assert(!(await denied.text()).includes("private SQL"));assertEquals(f.state.providers,0);
  f.reset({providerError:true});const failed=await f.handler(req());assertEquals(failed.status,503);
  const text=await failed.text();assert(text.includes("saved work is unchanged"));assert(!text.includes("credential"));assert(!text.includes("private prompt"));
  assertEquals(f.state.providers,1);assertEquals(f.state.ledgers,0);
});

Deno.test("Coach keeps an explicit workspace local draft as a device hint without claiming server status", async () => {
  const f=await fixture(),draft="c0100501-0000-4000-8000-000000000004";f.reset();
  assertEquals((await f.handler(req("c0300501-0000-4000-8000-000000000001","team",SELECTED_ORG,{context:{selected_listing_id:draft,listings:[{id:draft,local_draft:true,title:"Draft Street"}]}}))).status,200);
  assert(f.state.userTurn.includes(`Selected project id: ${draft}`));assert(f.state.userTurn.includes("server_status=unavailable"));
  assert(!f.state.contextQueries.some((q:any)=>q.table==="listings"&&!q.head));
});
