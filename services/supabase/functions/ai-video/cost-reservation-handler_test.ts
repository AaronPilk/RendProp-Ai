import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

const encode = (source: string) =>
  `data:application/typescript;base64,${
    btoa(String.fromCharCode(...new TextEncoder().encode(source)))
  }`;
function functionBody(source: string, name: string): string {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, `Missing production function ${name}`);
  const end = source.indexOf("\n}\n", start);
  assert(end > start);
  return source.slice(start, end + 3);
}
function withoutImports(source: string): string {
  return source.replace(/^import [\s\S]*?;\n/gm, "");
}

// Production route bodies, price arithmetic, response envelope and reservation
// helper run unchanged. Only Auth/DB, route resolution and provider boundaries
// are isolated doubles. No environment, network, writes or provider requests.
async function fixture(reserveLate = false, priceRequestedTier = false, dropRejectionEvidence = false, dropSigningReadiness = false) {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  const ledger = await Deno.readTextFile(
    new URL("../_shared/ledger.ts", import.meta.url),
  );
  const http = new URL("../_shared/http.ts", import.meta.url).href;
  let helper = withoutImports(
    await Deno.readTextFile(new URL("./cost-reservation.ts", import.meta.url)),
  );
  if (dropRejectionEvidence) {
    const original = "const rejected = (!dispatched || details?.dispatch_rejected === true)";
    assert(helper.includes(original), "Actual rejection classification anchor changed");
    helper = helper.replace(original, "const rejected = false && (!dispatched || details?.dispatch_rejected === true)");
  }
  if (reserveLate) {
    const start = helper.indexOf("  let reservation;");
    const end = helper.indexOf("  let attempt: ChainResult<T>;", start);
    assert(start > 0 && end > start);
    const reserve = helper.slice(start, end);
    helper = helper.slice(0, start) + helper.slice(end);
    const settle = helper.indexOf(
      '  try {\n    const settled = await deps.rpc("app_video_cost_settle"',
    );
    assert(settle > 0);
    helper = helper.slice(0, settle) + reserve + helper.slice(settle);
  }
  const helperUrl = encode(`
    import {HttpError,throwRpc} from ${JSON.stringify(http)};
    import {fundedAttempt,TARIFF_VERSION} from ${JSON.stringify(new URL("../_shared/funded-serving.ts",import.meta.url).href)};
    type RoutedUsage=any;type RouteStep=any;type ChainResult<T>={value:T,step:any};
    export ${functionBody(ledger, "unitsForStep")}
    ${helper}
  `);
  const priceStart = ledger.indexOf("export const APP_AI_UNIT_CENTS =");
  const priceEnd = ledger.indexOf("} as const;", priceStart) +
    "} as const;".length;
  assert(priceStart > 0 && priceEnd > priceStart);
  const prices = ledger.slice(priceStart, priceEnd);
  const droneUrl = encode(`
    import {HttpError,round4} from ${JSON.stringify(http)};
    ${prices}
    ${
    withoutImports(
      await Deno.readTextFile(new URL("./dronecost.ts", import.meta.url)),
    )
  }
  `);
  const start = source.indexOf("Deno.serve(async (req) => {");
  const drone = source.indexOf(
    '    if (req.method === "POST" && seg.length === 1 && seg[0] === "drone")',
    start,
  );
  const end = source.indexOf("    // ---- POST /ai-video/drift ----", drone);
  assert(start > 0 && drone > start && end > drone);
  const prelude = source.slice(start, drone).replace(
    "Deno.serve(async (req) => {",
    "export const handler = async (req: Request) => {",
  );
  let routes = source.slice(drone, end);
  if(dropSigningReadiness){
    const check="      await assertVideoReceiptSigningReady();\n";
    assertEquals(routes.split(check).length,4);routes=routes.split(check).join("");
  }
  if (priceRequestedTier) {
    const original = "        outputWidth,\n        outputHeight,";
    assert(routes.includes(original), "Actual-output mutation anchor changed");
    routes = routes.replace(
      original,
      "        outputWidth: tier === '1080p60' ? 1920 : outputWidth,\n        outputHeight: tier === '1080p60' ? 1080 : outputHeight,",
    );
  }
  const promptStart = source.indexOf("const SPACE_TYPES =");
  const promptEnd = source.indexOf("interface DroneBody", promptStart);
  assert(promptStart > 0 && promptEnd > promptStart);
  const constants = source.match(/^const MODEL_[A-Z0-9_]+ = [^;]+;/gm)!.join(
    "\n",
  );
  const body = `
    import {HttpError,assert,json,pathSegments,readJson,respondError} from ${
    JSON.stringify(http)
  };
    import {handleOptions} from ${
    JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)
  };
    import {requiredIdempotencyKey} from ${
    JSON.stringify(new URL("../_shared/idempotency.ts", import.meta.url).href)
  };
    import {GUARDRAILS,FAIR_HOUSING_LOCK,assertFairHousing} from ${
    JSON.stringify(new URL("../_shared/fairhousing.ts", import.meta.url).href)
  };
    import {AERIAL_MOTION_TEXT,AERIAL_MOTIONS,buildReelPrompt,chooseReelMotion,groundedAerialMotion,normalizeRoom,parseReelMotion,REEL_MOTION_LABEL,REEL_MOTIONS} from ${
    JSON.stringify(new URL("./motion.ts", import.meta.url).href)
  };
    import {APP_AI_UNIT_CENTS,assertDroneWithinLimits,droneReservation,DRONE_TIER_CENTS,DRONE_TIERS} from ${
    JSON.stringify(droneUrl)
  };
    import {submitReservedVideo,VideoDispatchUnconfirmed} from ${
    JSON.stringify(helperUrl)
  };
    type RouteStep=any;type JobRef=any;type JobTokenOwner=any;type ChainResult<T>={value:T,step:any};type GenerateInput=any;type DroneBody=any;type AerialBody=any;type ReelBody=any;type DroneEstimate=any;type AerialMotion=any;type ReelMotion=any;
    export const state:any={options:{},events:[],rpcs:[],posts:[],steps:[],probes:[],charges:[],refunds:0,oldLedger:0,admitted:new Set(),holds:new Map(),ledger:[]};
    export function reset(options:any={}){Object.assign(state,{options,events:[],rpcs:[],posts:[],steps:[],probes:[],charges:[],refunds:0,oldLedger:0,admitted:new Set(),holds:new Map(),ledger:[]});}
    const getUser=async(_req:Request)=>({id:"actor-synthetic",is_anonymous:false});
    const userClient=(_req:Request)=>({});
    const orgForUser=async(..._a:any[])=>"org-synthetic";
    const assertPaidAiIdentity=async(..._a:any[])=>{};
    const preferredOrg=(_req:Request)=>undefined;
    const extractEraseJob=(_req:Request)=>null;
    const eraseHandler=async(..._a:any[])=>{throw Error("Reflection route must not be reached");};
    const resolvePublicAsset=async(..._a:any[])=>({id:"asset-synthetic",org_id:"org-synthetic",listing_id:"listing-synthetic",kind:"video",url:"https://media-fixture.invalid/private-source-marker.mp4",duration_s:90,width:1920,height:1080,fps:60,space_type:"real_estate",transport_version:2,...state.options.asset});
    const probeMP4Video=async(url:string,..._a:any[])=>{state.probes.push(url);if(state.options.probeError)throw new HttpError(409,"Upload the saved clip again");return {duration_s:90,billable_s:90,width:1920,height:1080,fps:60,...state.options.verifiedSource};};
    const listingSpaceType=async(..._a:any[])=>"real_estate";
    const MAX_IMAGE_B64_CHARS=12000000,ALLOWED_IMAGE_MIMES=["image/jpeg","image/png","image/webp"];
    const ADVERTISED_SECONDS={"video.reel_clip":[5,6],"video.aerial":[6,8],"video.aerial_no_photo":[4,6,8]};
    ${constants}
    ${functionBody(source, "durationNeeds")}
    ${functionBody(source, "legacyVideoStep")}
    async ${functionBody(source, "submitEnvelope")}
    async ${functionBody(source, "assertVideoReceiptSigningReady")}
    const assertJobTokenSigningReady=async()=>{if(state.options.signerMissing)throw Error("No signer");};
    ${source.slice(promptStart, promptEnd)}
    ${functionBody(source, "cleanPrompt")}
    const guardGenerate=async(_user:any,req:Request,feature:any,cents:any,sourceOrgId?:string)=>{requiredIdempotencyKey(req);state.charges.push({feature,cents});state.sourceOrgId=sourceOrgId;return {orgId:sourceOrgId??"org-synthetic",plan:"team",monthlyKey:"monthly-synthetic",burstKey:"burst-synthetic",monthlyReceipt:{windowStart:"2026-10-05T00:00:00Z"},burstReceipt:{windowStart:"2026-10-05T01:00:00Z"}};};
    const refundGenerateCharge=async(..._a:any[])=>{state.refunds++;};
    const routerEnabled=async()=>state.options.routerOn??false;
    const resolveChain=async(task:any,_context:any,legacy:any)=>[state.options.badRoute?{...legacy,model:"unknown-tariff-model"}:state.options.routerOn?{...legacy,route_id:"live-shaped-route",model:task.startsWith("video.upscale_")?"topaz/upscale/video":legacy.model,unit_cents:task==="video.upscale_1080p60"?4:8}:legacy,{...legacy,route_id:"eligible-second",provider:"other",model:"second-model"}];
    const runChain=async(_task:any,steps:any[],callback:any)=>{state.steps.push(steps);return {step:steps[0],value:await callback(steps[0])};};
    class ProviderError extends Error {status?:number;error_class?:string;}
    const echo={request_id:"accepted-provider-id",status_url:"https://fixture.invalid/ai-video/status?job=opaque-fixture",response_url:"https://queue.fal.run/model/requests/accepted-provider-id"};
    const falSubmitEcho=(_id:string)=>echo;
    const routerStatusUrl=async(..._a:any[])=>{if(state.options.signerMissing)throw Error("No signer");return "https://fixture.invalid/ai-video/status?job=opaque-fixture";};
    const recordProvenance=async(..._a:any[])=>({id:"provenance-synthetic",recorded:true,disclosure:"AI edited video"});
    const recordRoutedAiCost=async(..._a:any[])=>{state.oldLedger++;throw Error("Legacy ledger double booking reached");};
    const recordAppAiCost=recordRoutedAiCost;
    const adapterFor=(provider:string)=>({submit:async(step:any,input:any)=>{state.events.push("POST");state.posts.push({provider,step,input});if(state.options.submitReject)throw new HttpError(502,"The media service could not accept this request.","upstream",{provider_status:state.options.submitReject,error_class:"upstream",dispatch_rejected:true});if(state.options.submitThrow)throw Error("private-provider-body-marker");return {id:state.options.badReceipt?"":"accepted-provider-id",provider};}});
    const adminClient=()=>({rpc:async(name:string,args:any)=>{
      if(name==="serving_cost_reserve")return {data:{reserved:true},error:null};
      if(name==="serving_cost_finish")return {data:{finished:true},error:null};
      if(name==="org_has_internal_testing_grant")return {data:true,error:null};
      state.events.push(name==="app_video_cost_reserve_v2"?"reserve":name==="app_video_cost_release_rejected"?"release":"settle");state.rpcs.push({name,args});
      if(name==="app_video_cost_reserve_v2"){
        if(state.admitted.has(args.p_key))return {data:null,error:{message:"RP409: This video request was already admitted"}};
        if(state.options.reserveError)return {data:null,error:{message:"RP402: Workspace processing budget reached"}};
        state.admitted.add(args.p_key);state.holds.set(args.p_key,args);
        return {data:state.options.reserveReply??{reserved:true},error:null};
      }
      if(name==="app_video_cost_release_rejected"){if(state.options.releaseError)return {data:null,error:{message:"private-release-error-marker"}};state.holds.delete(args.p_key);return {data:{released:true},error:null};}
      if(name!=="app_video_cost_settle")throw Error("Unexpected RPC");
      if(state.options.settleThrow)throw Error("private-database-body-marker");
      if(state.options.settleError)return {data:null,error:{message:"private-database-body-marker"}};
      if(state.options.settleReply)return {data:state.options.settleReply,error:null};
      const admitted=state.holds.get(args.p_key);state.holds.delete(args.p_key);state.ledger.push(admitted);
      return {data:{settled:true},error:null};
    }});
    ${prelude}${routes}
      throw new HttpError(404,"Unknown fixture route");
      } catch(error) {return respondError(error);}
    };
  `;
  return await import(encode(body));
}

const image = "c3ludGhldGljLXBpeGVscw==";
function req(
  route: "drone" | "aerial" | "reel-clip",
  key = "one-logical-video-tap",
  extra: Record<string, unknown> = {},
) {
  const input = route === "drone"
    ? { asset_id: "asset-synthetic", tier: "4k30", target_fps: 30, ...extra }
    : {
      image_b64: image,
      mime: "image/jpeg",
      seconds: route === "aerial" ? 6 : 5,
      ...extra,
    };
  return new Request(`https://fixture.invalid/ai-video/${route}`, {
    method: "POST",
    headers: { "content-type": "application/json", "idempotency-key": key },
    body: JSON.stringify(input),
  });
}
async function successfulSequence(
  f: Awaited<ReturnType<typeof fixture>>,
  route: "drone" | "aerial" | "reel-clip",
) {
  const response = await f.handler(req(route));
  assertEquals(response.status, 202);
  assertEquals(f.state.events, ["reserve", "POST", "settle"]);
  assertEquals(f.state.posts.length, 1);
  assertEquals(f.state.steps[0].length, 1);
  assertEquals(f.state.oldLedger, 0);
  assertEquals(f.state.ledger.length, 1);
  assertEquals(f.state.holds.size, 0);
  assertEquals(f.state.refunds, 0);
  const body = await response.json();
  assertEquals(body.request_id, "accepted-provider-id");
  assertEquals(
    body.status_url,
    "https://fixture.invalid/ai-video/status?job=opaque-fixture",
  );
  assertEquals(
    body.response_url,
    "https://fixture.invalid/ai-video/status?job=opaque-fixture",
  );
  return body;
}

for (const route of ["drone", "aerial", "reel-clip"] as const) {
  Deno.test(`${route} actual handler reserves before one POST and settles once with existing receipt fields`, async () => {
    const f = await fixture();
    f.reset();
    await successfulSequence(f, route);
    const receipt = JSON.stringify(f.state.rpcs);
    assert(
      !receipt.includes("private-source-marker") && !receipt.includes(image),
    );
    assert(
      !receipt.includes("prompt") && !receipt.includes("image_url") &&
        !receipt.includes("video_url") && !receipt.includes('"room"'),
    );
    assertEquals(
      f.state.rpcs[0].args.p_provider,
      f.state.posts[0].step.provider,
    );
    assertEquals(f.state.rpcs[0].args.p_model, f.state.posts[0].step.model);
    assert(/^[a-f0-9]{64}$/.test(f.state.rpcs[0].args.p_input_sha256));
    assertEquals((await f.handler(req(route))).status, 409);
    assertEquals(
      f.state.posts.length,
      1,
      "Persistent duplicate reached a second provider POST",
    );
    assertEquals(f.state.ledger.length, 1);
  });
  Deno.test(`${route} actual handler retains unconfirmed dispatch without fallback, settlement or allowance refund`, async () => {
    const f = await fixture();
    f.reset({ submitThrow: true });
    const response = await f.handler(req(route));
    assertEquals(response.status, 502);
    assertEquals(f.state.events, ["reserve", "POST"]);
    assertEquals(f.state.posts.length, 1);
    assertEquals(f.state.holds.size, 1);
    assertEquals(f.state.refunds, 0);
    assertEquals(f.state.ledger.length, 0);
    assert(!(await response.text()).includes("private-provider-body-marker"));
  });
  Deno.test(`${route} actual handler returns accepted receipt when ledger settlement is unavailable`, async () => {
    const f = await fixture();
    for (
      const options of [{ settleThrow: true }, { settleError: true }, {
        settleReply: {},
      }]
    ) {
      f.reset(options);
      const response = await f.handler(req(route));
      assertEquals(response.status, 202);
      assertEquals((await response.json()).request_id, "accepted-provider-id");
      assertEquals(f.state.events, ["reserve", "POST", "settle"]);
      assertEquals(f.state.posts.length, 1);
      assertEquals(f.state.holds.size, 1);
      assertEquals(f.state.ledger.length, 0);
      assertEquals(f.state.oldLedger, 0);
      assertEquals(f.state.refunds, 0);
    }
  });
}

Deno.test("Topaz actual handler pins the frame-scaled estimate to both hold and settled price", async () => {
  const f = await fixture();
  f.reset();
  const body = await successfulSequence(f, "drone");
  assertEquals(body.estimated_cost.unit_cents, 16);
  assertEquals(body.estimated_cost.cents, 1440);
  assertEquals(f.state.ledger[0].p_units, 90);
  assertEquals(f.state.ledger[0].p_unit_cost_cents, 16);
  assertEquals(f.state.ledger[0].p_hold_cents, 1440);
});

async function actual4KHold(f: Awaited<ReturnType<typeof fixture>>) {
  f.reset({
    routerOn: true,
    // The upload hints deliberately lie. They cannot affect the price.
    asset: { width: 1920, height: 1080, fps: 30, duration_s: 5 },
    verifiedSource: {
      width: 3840,
      height: 2160,
      fps: 60,
      duration_s: 300,
      billable_s: 300,
    },
  });
  const response = await f.handler(
    req("drone", "actual-4k-source", { tier: "1080p60", target_fps: 60 }),
  );
  assertEquals(response.status, 202);
  const body = await response.json();
  assertEquals(body.upscale_factor, 1);
  assertEquals(f.state.posts[0].input.extra, { upscale_factor: 1 });
  assertEquals(body.source, {
    width: 3840,
    height: 2160,
    fps: 60,
    duration_s: 300,
  });
  assertEquals(body.estimated_cost.cents, 4800);
  assertEquals(body.estimated_cost.unit_cents, 16);
  assertEquals(f.state.charges, [{ feature: "drone", cents: 4800 }]);
  assertEquals(f.state.ledger[0].p_hold_cents, 4800);
  assertEquals(f.state.ledger[0].p_unit_cost_cents, 16);
  assertEquals(f.state.ledger[0].p_units, 300);
  assertEquals(body.estimated_cost.output_width, 3840);
  assertEquals(body.estimated_cost.output_height, 2160);
  assertEquals(f.state.posts.length, 1);
  assertEquals(f.state.probes.length, 1);
  assertEquals(f.state.sourceOrgId, "org-synthetic");
}

Deno.test("Topaz enabled live-shaped 1080 route holds and settles $48 for a verified 4K60 five-minute source", async () => {
  await actual4KHold(await fixture());
});

Deno.test("pricing the requested tier rather than actual output is caught by the same handler contract", async () => {
  const mutant = await fixture(false, true);
  await assertRejects(() => actual4KHold(mutant));
  assertEquals(
    mutant.state.posts.length,
    1,
    "Negative control failed before its behavioral defect",
  );
  assertEquals(
    mutant.state.ledger[0].p_hold_cents,
    4800,
    "Conservative reservation must survive even an underpriced informational estimate",
  );
});

Deno.test("Topaz unsupported sources and frame rates fail before quota, hold and provider", async () => {
  const f = await fixture();
  for (
    const [options, input, expected] of [
      [{ asset: { transport_version: 1 } }, {}, 409],
      [{ probeError: true }, {}, 409],
      [{ verifiedSource: { fps: 120 } }, {}, 409],
      [{ verifiedSource: { billable_s: 301 } }, {}, 400],
      [{ verifiedSource: { width: 7680, height: 4320 } }, {}, 400],
      [{}, { target_fps: 120 }, 400],
    ] as const
  ) {
    f.reset(options);
    const response = await f.handler(req("drone", "unsupported-source", input));
    assertEquals(response.status, expected);
    assertEquals(f.state.charges.length, 0);
    assertEquals(f.state.rpcs.length, 0);
    assertEquals(f.state.posts.length, 0);
  }
});

Deno.test("Topaz refuses an unpriced provider/model and refunds its unused allowance", async () => {
  const f = await fixture();
  f.reset({ badRoute: true });
  assertEquals((await f.handler(req("drone"))).status, 503);
  assertEquals(f.state.rpcs.length, 0);
  assertEquals(f.state.posts.length, 0);
  assertEquals(f.state.refunds, 1);
});

Deno.test("Topaz cheaper informational estimates retain the highest published tariff in hold and ledger", async () => {
  const f = await fixture();
  f.reset({
    routerOn: true,
    verifiedSource: {
      width: 1920,
      height: 1080,
      fps: 30,
      duration_s: 30,
      billable_s: 30,
    },
  });
  const response = await f.handler(
    req("drone", "conservative-cheap-bucket", {
      tier: "1080p60",
      target_fps: 30,
    }),
  );
  assertEquals(response.status, 202);
  const body = await response.json();
  assertEquals(body.estimated_cost.unit_cents, 2);
  assertEquals(body.estimated_cost.cents, 60);
  assertEquals(body.reserved_cost, {
    unit_cents: 16,
    cents: 480,
    usd: "4.80",
    basis: "published_maximum_tariff",
  });
  assertEquals(f.state.charges, [{ feature: "drone", cents: 480 }]);
  assertEquals(f.state.ledger[0].p_hold_cents, 480);
  assertEquals(f.state.ledger[0].p_unit_cost_cents, 16);
  assertEquals(f.state.ledger[0].p_meta.estimate_cents, 480);
});

Deno.test("actual paid guard binds a resolved asset workspace when a multi-org caller omits X-Org-Id", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  const http = new URL("../_shared/http.ts", import.meta.url).href;
  const idem = new URL("../_shared/idempotency.ts", import.meta.url).href;
  const module = await import(encode(`
    import {HttpError} from ${JSON.stringify(http)};
    import {requiredIdempotencyKey} from ${JSON.stringify(idem)};
    type PaidAiCaller=any;type GenKind=any;type GenerateCharge=any;
    export const state:any={choices:[],meters:[]};
    const preferredOrg=(req:Request)=>req.headers.get('X-Org-Id')??undefined;
    const orgForUser=async(_u:string,preferred?:string)=>{state.choices.push(preferred);return preferred??'different-default-org';};
    const contentOrgForUser=orgForUser;
    const libraryBillingOrg=async(_admin:any,org:string,_actor:string)=>org;
    const adminClient=()=>({from:()=>({select:()=>({eq:()=>({eq:()=>({maybeSingle:async()=>({data:{role:'owner'},error:null})})})})})});
    const assertPaidAiIdentity=async(..._a:any[])=>{};
    const entitlementForCharge=async(_o:string)=>({plan:'team',cogs_ceiling_cents:6000});
    const capFor=(..._a:any[])=>2,labelFor=(..._a:any[])=>'drone',meterKeyFor=(..._a:any[])=>'drone';
    const quotaError=(..._a:any[])=>new HttpError(402,'quota');
    const orgMonthSpendCents=async(..._a:any[])=>0;
    const assertMonthlyHeadroom=(..._a:any[])=>{};
    const durableRateLimit=async(key:string,..._a:any[])=>{state.meters.push(key);return true;};
    const chargeRateReceipt=async(key:string,..._a:any[])=>{state.meters.push(key);return {accepted:true,receipt:{key,windowStart:"2026-10-05T00:00:00Z"}};};
    const refundRateReceipt=async()=>true;
    const GEN_MAX_PER_WINDOW=8,GEN_WINDOW_SECONDS=60,MONTH_SECONDS=2592000;
    export async ${functionBody(source, "guardGenerate")}
  `));
  const request = req("drone", "workspace-binding");
  const charge = await module.guardGenerate(
    { id: "member-of-two-orgs" },
    request,
    "drone",
    4800,
    "asset-owner-org",
  );
  assertEquals(charge.orgId, "asset-owner-org");
  assertEquals(module.state.choices, ["asset-owner-org"]);
  assert(
    module.state.meters.every((key: string) => key.includes("asset-owner-org")),
  );
});

Deno.test("all actual routes require affirmative reservation rather than an empty RPC reply", async () => {
  const f = await fixture();
  for (const route of ["drone", "aerial", "reel-clip"] as const) {
    for (
      const reserveReply of [{}, { reserved: false }, { reserved: "true" }]
    ) {
      f.reset({ reserveReply });
      assertEquals((await f.handler(req(route))).status, 503);
      assertEquals(f.state.events, ["reserve"]);
      assertEquals(f.state.posts.length, 0);
      assertEquals(f.state.ledger.length, 0);
    }
  }
});

Deno.test("existing signed status-envelope shape survives the reserved dispatch path", async () => {
  const f = await fixture();
  f.reset({ routerOn: true });
  const response = await f.handler(req("reel-clip"));
  assertEquals(response.status, 202);
  const body = await response.json();
  assertEquals(body.request_id, "accepted-provider-id");
  assertEquals(
    body.status_url,
    "https://fixture.invalid/ai-video/status?job=opaque-fixture",
  );
  assertEquals(body.response_url, body.status_url);
});

async function assertSignerBeforeAdmission(f:any,route:"drone"|"aerial"|"reel-clip"){
  f.reset({signerMissing:true});
  const before=console.error;console.error=()=>{};
  try{
    assertEquals((await f.handler(req(route))).status,503,"missing signer must refuse before any quota or provider admission");
    assertEquals(f.state.charges,[],"missing signer must refuse before any quota or provider admission");
    assertEquals(f.state.posts,[],"missing signer must refuse before any quota or provider admission");
    assertEquals(f.state.events,[],"missing signer must refuse before any quota or provider admission");
  }finally{console.error=before;}
}
Deno.test("all actual video handlers preflight receipt signing before quota and priced POST",async()=>{
  const f=await fixture();for(const route of ["drone","aerial","reel-clip"]as const)await assertSignerBeforeAdmission(f,route);
});
Deno.test("compiled omitted signer preflight reproduces accepted paid work with no returned receipt",async()=>{
  const mutant=await fixture(false,false,false,true);
  for(const route of ["drone","aerial","reel-clip"]as const){
    await assertRejects(()=>assertSignerBeforeAdmission(mutant,route),Error,"missing signer must refuse before any quota or provider admission");
    assertEquals(mutant.state.posts.length,1);
    assertEquals(mutant.state.events,["reserve","POST","settle"]);
  }
});

Deno.test("moving the actual reservation after POST is caught by the same route contract", async () => {
  const mutant = await fixture(true);
  mutant.reset();
  await assertRejects(() => successfulSequence(mutant, "drone"));
  assertEquals(mutant.state.events, ["POST", "reserve", "settle"]);
});

for (const route of ["drone", "aerial", "reel-clip"] as const) {
  Deno.test(`${route} actual handler refunds allowance only after definitive rejection hold release commits`, async () => {
    const f = await fixture();
    f.reset({ submitReject: 403 });
    const response = await f.handler(req(route));
    assertEquals(response.status, 502);
    assertEquals(f.state.events, ["reserve", "POST", "release"]);
    assertEquals(f.state.posts.length, 1);
    assertEquals(f.state.holds.size, 0);
    assertEquals(f.state.refunds, 1);
    assertEquals(f.state.ledger.length, 0);
    assertEquals((await response.json()).provider_status, 403);
  });
  Deno.test(`${route} actual handler retains allowance and hold when rejection release fails`, async () => {
    const f = await fixture();
    f.reset({ submitReject: 403, releaseError: true });
    const response = await f.handler(req(route));
    assertEquals(response.status, 502);
    assertEquals(f.state.events, ["reserve", "POST", "release"]);
    assertEquals(f.state.holds.size, 1);
    assertEquals(f.state.refunds, 0);
    assertEquals(f.state.ledger.length, 0);
    assert(!(await response.text()).includes("private-release-error-marker"));
  });
}

Deno.test("dropping actual rejection evidence is caught by the same release/refund contract", async () => {
  const f = await fixture(false, false, true);
  f.reset({ submitReject: 403 });
  const response = await f.handler(req("reel-clip"));
  assertEquals(response.status, 502);
  let caught = false;
  try {
    assertEquals(f.state.events, ["reserve", "POST", "release"], "Definitive rejection must release before refund");
    assertEquals(f.state.holds.size, 0);
    assertEquals(f.state.refunds, 1);
  } catch (error) {
    assert(error instanceof Error && error.message.includes("Definitive rejection must release before refund"));
    caught = true;
  }
  assert(caught, "Control must fail the production release/refund invariant");
});
