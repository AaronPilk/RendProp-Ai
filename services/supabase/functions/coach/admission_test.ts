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
  const orgEnd = shared.indexOf("/** Read an optional preferred org", orgStart);
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
    import {HttpError,assert,json,pathSegments,readJson,respondError} from ${
    JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
  };
    import {handleOptions} from ${
    JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)
  };
    import {buildUserTurn,screenOf,spaceTypeOf,systemInstruction} from ${
    JSON.stringify(new URL("./prompt.ts", import.meta.url).href)
  };
    import {parseCoachOutput} from ${
    JSON.stringify(new URL("./actions.ts", import.meta.url).href)
  };
    type RouteStep=any;type CoachContext=any;type CoachListingCtx=any;
    export const state:any={options:{},providers:0,ledgers:0,ledgerRows:[],orgLookups:[],meters:[],plans:[],events:[],counts:new Map()};
    export function reset(options:any={}){Object.assign(state,{options,providers:0,ledgers:0,ledgerRows:[],orgLookups:[],meters:[],plans:[],events:[],counts:new Map()});}
    const getUser=async(req:Request)=>({id:req.headers.get("x-test-user")??"synthetic-user",is_anonymous:false});
    const ROLE_RANK={owner:0,admin:1,agent:2,marketing:3};
    const adminClient=()=>({
      from:(table:string)=>{state.events.push("org");const filters:any={};return {
        select(){return this;},eq(key:string,value:string){filters[key]=value;return this;},
        async maybeSingle(){state.orgLookups.push({table,...filters});return {error:null,data:!state.options.noOrg&&[${
    JSON.stringify(SELECTED_ORG)
  },${
    JSON.stringify(ACTIVE_ORG)
  }].includes(filters.org_id)?{org_id:filters.org_id}:null};}
      };},
      rpc:async(name:string,args:any)=>{state.events.push("org");state.orgLookups.push({name,args});return {error:null,data:${
    JSON.stringify(ACTIVE_ORG)
  }};}
    });
    ${actualHeader}
    ${actualMembership}
    const assertPaidAiIdentity=async(..._a:any[])=>{state.events.push("identity");if(state.options.identityDenied)throw new HttpError(401,"Sign in required");};
    const entitlementFor=async(..._a:any[])=>{state.events.push("plan");if(state.options.planError)throw Error("Synthetic plan outage");return {plan:state.options.plan??"team",degraded:state.options.degraded??false};};
    const durableRateLimit=async(key:string,max:number,seconds:number)=>{state.meters.push({key,max,seconds});const n=state.counts.get(key)??0;if(n>=max)return false;state.counts.set(key,n+1);return true;};
    const resolveRoute=async(_task:any,context:any)=>{state.plans.push(context.plan);return [];};
    const runChain=async(_task:any,steps:any[],callback:any)=>({value:await callback(steps[0]),step:steps[0]});
    const anthropicMessages=async(args:any)=>{state.events.push("provider");state.providers++;state.maxTokens=args.maxTokens;state.system=args.system;state.userTurn=args.content[0].text;return JSON.stringify({reply:"Start with a clear photo of each room.",actions:[],suggested_replies:[]});};
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
  user = "synthetic-user",
  plan = "brokerage",
  org: string | null = SELECTED_ORG,
  extras: Record<string, unknown> = {},
) {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-test-user": user,
  };
  if (org !== null) headers["X-Org-Id"] = org;
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
      (await f.handler(req("synthetic-user", "brokerage"))).status,
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

Deno.test("coach membership negative control reaches paid work when the source check is bypassed", async () => {
  const mutant = await fixture(true);
  await assertRejects(() => assertNoOrgDenied(mutant));
  assertEquals(mutant.state.providers, 1);
});

async function assertSelectedWorkspace(f: Awaited<ReturnType<typeof fixture>>) {
  f.reset();
  assertEquals(
    (await f.handler(
      req("synthetic-user", "brokerage", SELECTED_ORG.toUpperCase()),
    )).status,
    200,
  );
  assertEquals(f.state.orgLookups, [{
    table: "memberships",
    user_id: "synthetic-user",
    org_id: SELECTED_ORG,
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
      (await f.handler(req("synthetic-user", "team", org))).status,
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
        req("synthetic-user", "team", SELECTED_ORG, { context: { screen } }),
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
        req("synthetic-user", "team", SELECTED_ORG, { space_type: space }),
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
        req("synthetic-user", "team", SELECTED_ORG, { context: { screen } }),
      )).status,
      200,
    );
    assertEquals(f.state.ledgerRows[0].meta.screen, null);
    assert(!f.state.userTurn.includes("123 Synthetic Address"));
  }
});
