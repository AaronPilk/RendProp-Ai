import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// Execute the complete current handler plus its real input/output sanitizers.
// Only Auth, workspace/plan/meter/ledger and provider boundaries are doubles.
async function fixture(bypassMembership = false) {
  let source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  source = source.replace(/^import [\s\S]*?;\n/gm, "");
  source = source.replace(
    "Deno.serve(async (req) => {",
    "export const handler = async (req: Request) => {",
  );
  assert(source.endsWith("});\n"));
  source = source.slice(0, -4) + "};\n";
  if (bypassMembership) {
    source = source.replace(
      "await orgForUser(user.id, preferredOrg(req))",
      '"synthetic-org"',
    );
  }
  const code = `
    import {HttpError,assert,json,pathSegments,readJson,respondError} from ${
    JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
  };
    import {handleOptions} from ${
    JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)
  };
    import {buildUserTurn,spaceTypeOf,systemInstruction} from ${
    JSON.stringify(new URL("./prompt.ts", import.meta.url).href)
  };
    import {parseCoachOutput} from ${
    JSON.stringify(new URL("./actions.ts", import.meta.url).href)
  };
    type RouteStep=any;type CoachContext=any;type CoachListingCtx=any;
    export const state:any={options:{},providers:0,ledgers:0,meters:[],plans:[],events:[],counts:new Map()};
    export function reset(options:any={}){Object.assign(state,{options,providers:0,ledgers:0,meters:[],plans:[],events:[],counts:new Map()});}
    const getUser=async(req:Request)=>({id:req.headers.get("x-test-user")??"synthetic-user",is_anonymous:false});
    const orgForUser=async(..._a:any[])=>{state.events.push("org");if(state.options.noOrg)throw new HttpError(403,"Synthetic missing membership");return "synthetic-org";};
    const preferredOrg=(..._a:any[])=>undefined;
    const assertPaidAiIdentity=async(..._a:any[])=>{state.events.push("identity");if(state.options.identityDenied)throw new HttpError(401,"Sign in required");};
    const entitlementFor=async(..._a:any[])=>{state.events.push("plan");if(state.options.planError)throw Error("Synthetic plan outage");return {plan:state.options.plan??"team",degraded:state.options.degraded??false};};
    const durableRateLimit=async(key:string,max:number,seconds:number)=>{state.meters.push({key,max,seconds});const n=state.counts.get(key)??0;if(n>=max)return false;state.counts.set(key,n+1);return true;};
    const resolveRoute=async(_task:any,context:any)=>{state.plans.push(context.plan);return [];};
    const runChain=async(_task:any,steps:any[],callback:any)=>({value:await callback(steps[0]),step:steps[0]});
    const anthropicMessages=async(args:any)=>{state.events.push("provider");state.providers++;state.maxTokens=args.maxTokens;return JSON.stringify({reply:"Start with a clear photo of each room.",actions:[],suggested_replies:[]});};
    const openaiChat=anthropicMessages;
    class ProviderError extends Error{}
    const adminClient=()=>({});
    const recordRoutedAiCost=async(..._a:any[])=>{state.events.push("ledger");state.ledgers++;return {recorded:true};};
    ${source}
  `;
  return await import(
    `data:application/typescript;base64,${
      btoa(String.fromCharCode(...new TextEncoder().encode(code)))
    }`
  );
}

function req(user = "synthetic-user", plan = "brokerage") {
  return new Request("https://fixture.invalid/coach", {
    method: "POST",
    headers: { "content-type": "application/json", "x-test-user": user },
    body: JSON.stringify({
      messages: [{ role: "user", content: "Help me get started" }],
      context: { plan },
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
      key: "coachorgday:synthetic-org",
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
