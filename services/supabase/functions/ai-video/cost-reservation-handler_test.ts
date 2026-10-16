import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
Deno.env.set("SUPABASE_URL", "https://aaaaaaaaaaaaaaaaaaaa.supabase.co");

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
// are isolated doubles. Only synthetic config; no network, writes or provider requests.
async function fixture(reserveLate = false, priceRequestedTier = false, dropRejectionEvidence = false, dropSigningReadiness = false, dropAerialLaunchGate = false, legacyDirectSource = false) {
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
    import {HttpError,throwRpc,isTrialCapacityRefusal,TRIAL_CAPACITY_UNAVAILABLE_MESSAGE} from ${JSON.stringify(http)};
    import {ceilingRefusalCopy,fundedAttempt,TARIFF_VERSION} from ${JSON.stringify(new URL("../_shared/funded-serving.ts",import.meta.url).href)};
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
  const start = source.indexOf("export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {");
  const drone = source.indexOf(
    '    if (req.method === "POST" && seg.length === 1 && seg[0] === "drone")',
    start,
  );
  const end = source.indexOf("    // ---- POST /ai-video/drift ----", drone);
  assert(start > 0 && drone > start && end > drone);
  const prelude = source.slice(start, drone).replace(
    "export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {",
    `export const handler = async (req: Request,suppliedWorker?:any) => {const worker=suppliedWorker??(state.options.background?{user:{id:"actor-synthetic",is_anonymous:false},targetAspect:"16:9",authorize:async()=>{state.events.push("fresh-worker-authority");},accepted:async(r:any)=>{state.accepted=r;state.events.push("saved-accepted-receipt");},provenance:async()=>{state.events.push("worker-provenance");if(state.options.provenanceError)throw Error("closed provenance outage");return{id:"provenance-synthetic",recorded:true};}}:undefined);`,
  );
  let routes = source.slice(drone, end);
  if(legacyDirectSource){const needle="if(!worker&&propertySource){";assertEquals(routes.split(needle).length,2);routes=routes.replace(needle,"if(false&&!worker&&propertySource){");}
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
  if (dropAerialLaunchGate) {
    const gate = "const aerialOrgId = await assertAerialLaunchAccess(user, req, body.listing_id ?? assetListingId);";
    assert(routes.includes(gate), "Aerial launch entry anchor changed");
    routes = routes.replace(gate, 'const aerialOrgId = "org-synthetic";');
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
    import {recordDirectPropertyVideoSource} from ${JSON.stringify(new URL("./property-source-provenance.ts",import.meta.url).href)};
    import {optionalUuid,type ProvenanceResult} from ${JSON.stringify(new URL("../_shared/provenance.ts",import.meta.url).href)};
    import {assertPublicSupabaseOrigin} from ${JSON.stringify(new URL("../_shared/providers/jobtoken.ts", import.meta.url).href)};
    import {GUARDRAILS,FAIR_HOUSING_LOCK,assertFairHousing} from ${
    JSON.stringify(new URL("../_shared/fairhousing.ts", import.meta.url).href)
  };
    import {AERIAL_MOTION_TEXT,AERIAL_MOTIONS,buildReelPrompt,buildSeedanceReelPreset,REEL_PRESETS,chooseReelMotion,groundedAerialMotion,normalizeRoom,parseReelMotion,REEL_MOTION_LABEL,REEL_MOTIONS} from ${
    JSON.stringify(new URL("./motion.ts", import.meta.url).href)
  };
    import {APP_AI_UNIT_CENTS,assertDroneWithinLimits,droneReservation,DRONE_TIER_CENTS,DRONE_TIERS} from ${
    JSON.stringify(droneUrl)
  };
    import {submitReservedVideo,VideoDispatchUnconfirmed} from ${
    JSON.stringify(helperUrl)
  };
    import {ownerQaReelStep as actualOwnerQaReelStep,prepareOwnerQaReelInput} from ${
    JSON.stringify(new URL("./owner-reel-qa.ts", import.meta.url).href)
  };
    import {OWNER_RAIL_MOTION_PROFILE} from ${JSON.stringify(new URL("../_shared/property-motion-profile.ts", import.meta.url).href)};
    import {parseReelFraming,reelFramingSteps,buildPhotoPreservingReelPrompt,buildPropertyCanvasReelPrompt,buildSteadyPropertyReelPrompt} from ${
    JSON.stringify(new URL("./reel-framing.ts", import.meta.url).href)
  };
    import {PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE,isPropertyVideoQualityProfile,propertyVideoQualityProfile,propertyVideoQualitySteps as actualPropertyVideoQualitySteps} from ${JSON.stringify(new URL("./property-video-quality.ts", import.meta.url).href)};
    import {paramsOf} from ${
    JSON.stringify(new URL("../_shared/router.ts", import.meta.url).href)
  };
    import {validateExtendedReelSource} from ${
    JSON.stringify(new URL("./drift-input.ts", import.meta.url).href)
  };
    import {unlimitedSponsored} from ${JSON.stringify(new URL("../_shared/funded-serving.ts", import.meta.url).href)};
    type PaidAiCaller=any;
    type RouteStep=any;type JobRef=any;type JobTokenOwner=any;type ChainResult<T>={value:T,step:any};type GenerateInput=any;type DroneBody=any;type AerialBody=any;type ReelBody=any;type DroneEstimate=any;type AerialMotion=any;type ReelMotion=any;
    export const state:any={options:{},events:[],rpcs:[],posts:[],steps:[],probes:[],charges:[],refunds:0,oldLedger:0,legacyProvenanceCalls:0,admitted:new Set(),holds:new Map(),ledger:[]};
    export function reset(options:any={}){Object.assign(state,{options,events:[],rpcs:[],posts:[],steps:[],probes:[],charges:[],grantReads:[],access:null,billing:null,refunds:0,oldLedger:0,legacyProvenanceCalls:0,profileReads:0,admitted:new Set(),holds:new Map(),ledger:[]});}
    const getUser=async(_req:Request)=>({id:"actor-synthetic",is_anonymous:false});
    const userClient=(_req:Request)=>({});
    const orgForUser=async(..._a:any[])=>"org-synthetic";
    const contentOrgForUser=async(actor:string,preferred:any,listing:any,write:boolean)=>{state.access={actor,preferred,listing,write};if(state.options.accessDenied)throw new HttpError(403,"This listing is unavailable.");return state.options.contentOrg??"org-synthetic";};
    const libraryBillingOrg=async(_admin:any,org:string,actor:string)=>{state.billing={org,actor};if(state.options.billingDenied)throw new HttpError(403,"Current billing unavailable.");return state.options.billingOrg??org;};
    const assertPaidAiIdentity=async(..._a:any[])=>{if(state.options.identityDenied)throw new HttpError(401,"Sign in required.");};
    async ${functionBody(source, "assertAerialLaunchAccess")}

    const preferredOrg=(req:Request)=>req.headers.get("X-Org-Id")??undefined;
    // The real helper is exercised against a closed, disabled QA grant. No
    // live Supabase client/config can enter this ordinary-route harness.
    const ownerQaReelStep=(args:any)=>actualOwnerQaReelStep(args,{from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:{value:{enabled:false}},error:null})})})})}as any);
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
    import {asHttpError} from ${JSON.stringify(new URL("../_shared/providers/chain.ts", import.meta.url).href)};
    const runChain=async(_task:any,steps:any[],callback:any)=>{state.steps.push(steps);try{return {step:steps[0],value:await callback(steps[0])};}catch(error){throw asHttpError(error);}};
    import {ProviderError} from ${JSON.stringify(new URL("../_shared/providers/common.ts", import.meta.url).href)};
    const propertyVideoQualitySteps=async(plan:string)=>{state.profileReads=(state.profileReads??0)+1;if(state.options.profileUnavailable||state.options.profileRevoked&&state.profileReads>1)throw new HttpError(503,"Closed profile unavailable");return actualPropertyVideoQualitySteps(plan,async()=>[{route_id:"ordinary-property-profile",task:"video.property_reel_clip",provider:"fal",model:"fal-ai/kling-video/v3/4k/image-to-video",unit:"second",unit_cents:42,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true}]);};
    const echo={request_id:"accepted-provider-id",status_url:"https://fixture.invalid/ai-video/status?job=opaque-fixture",response_url:"https://queue.fal.run/model/requests/accepted-provider-id"};
    const falSubmitEcho=(_id:string)=>echo;
    const routerStatusUrl=async(..._a:any[])=>{if(state.options.background)state.events.push("signed-worker-receipt");if(state.options.signerMissing)throw Error("No signer");return "https://fixture.invalid/ai-video/status?job=opaque-fixture";};
    const recordProvenance=async(..._a:any[])=>{state.legacyProvenanceCalls++;return{id:"provenance-synthetic",recorded:true,disclosure:"AI edited video"};};
    const verifyPropertyVideoInput=async(_actor:string,listing:string,asset:string,_b64:string,photoProvenance:string|null)=>({asset,listing,photoProvenance,sha256:"a".repeat(64),qcHash:"b".repeat(32),org:"org-synthetic"});
    const retainVideoSubmission=async(..._a:any[])=>{state.events.push("retained-accepted");};
    const recordRoutedAiCost=async(..._a:any[])=>{state.oldLedger++;throw Error("Legacy ledger double booking reached");};
    const recordAppAiCost=recordRoutedAiCost;
    const adapterFor=(provider:string)=>({submit:async(step:any,input:any)=>{state.events.push("POST");state.posts.push({provider,step,input});if(state.options.submitReject)throw new HttpError(502,"The media service could not accept this request.","upstream",{provider_status:state.options.submitReject,error_class:"upstream",dispatch_rejected:true});if(state.options.submitThrow)throw Error("private-provider-body-marker");return {id:state.options.badReceipt?"":"accepted-provider-id",provider};}});
    const adminClient=()=>({rpc:async(name:string,args:any)=>{
      if(name==="serving_cost_reserve")return {data:{reserved:true},error:null};
      if(name==="serving_cost_finish")return {data:{finished:true},error:null};
      if(name==="org_has_internal_testing_grant"||name==="org_has_private_internal_testing"){
        state.grantReads??=[];state.grantReads.push({name,args});
        if(state.options.grantThrow)throw Error("Synthetic private failure");
        if(state.options.grantError)return {data:null,error:{message:"Synthetic private failure"}};
        return {data:name==="org_has_internal_testing_grant"?(state.options.masterGrant??!state.options.ordinary):(state.options.privateGrant??false),error:null};
      }
      state.events.push(name==="app_video_cost_reserve_v2"?"reserve":name==="app_video_cost_release_rejected"?"release":"settle");state.rpcs.push({name,args});
      if(name==="record_direct_property_video_source"){
        state.events.push("direct-source-provenance");
        if(state.options.sourceAuditThrow)throw Error("private-audit-error-marker");
        if(state.options.sourceAuditError)return{data:null,error:{message:"private-audit-error-marker"}};
        return{data:state.options.sourceAuditReply??{bound:true,request_id:args.p_request,provenance_id:"fa850000-0000-4000-8000-000000000001",disclosure:"SQL-derived reel disclosure"},error:null};
      }
      if(name==="bind_property_video_source")return{data:{bound:true},error:null};
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
Deno.test("unsafe public origin refuses all actual video routes before quota, holds or provider POST",async()=>{
  const prior=Deno.env.get("SUPABASE_URL"),f=await fixture();
  try {
    for(const value of [undefined,"http://aaaaaaaaaaaaaaaaaaaa.supabase.co","https://foreign.invalid","https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1"]){
      value===undefined?Deno.env.delete("SUPABASE_URL"):Deno.env.set("SUPABASE_URL",value);
      for(const route of ["drone","aerial","reel-clip"]as const){
        f.reset();assertEquals((await f.handler(req(route))).status,503);assertEquals(f.state.charges,[]);assertEquals(f.state.posts,[]);assertEquals(f.state.events,[]);
      }
    }
  } finally {prior===undefined?Deno.env.delete("SUPABASE_URL"):Deno.env.set("SUPABASE_URL",prior);}
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

Deno.test("actual reel handler rejects invalid presets before admission and dispatch", async () => {
  const f = await fixture();
  for (const extra of [
    {preset_version:2,motion:"fly_through",aspect:"9:16"},
    {preset_version:1,motion:"orbit_left",aspect:"9:16"},
    {preset_version:1,motion:"fly_through",aspect:"square"},
    {preset_version:1,motion:"fly_through",aspect:"9:16",prompt:"repaint the house"},
    {preset_version:1,motion:"fly_through",aspect:"9:16",seconds:6},
  ]) {
    f.reset(); const response = await f.handler(req("reel-clip", "bad-preset", extra));
    assertEquals(response.status, 400); assertEquals(f.state.events, []);
    assertEquals(f.state.posts.length, 0);
  }
});
Deno.test("actual reel handler carries both delivery formats through the same funded five-second dispatch", async () => {
  const f = await fixture();
  let holdCents: number | undefined;
  for (const framing of [undefined, "preserve_photo"] as const) {
    for (const aspect of ["9:16", "16:9"] as const) {
      f.reset();
      const response = await f.handler(req("reel-clip", `preset-${aspect}-${framing ?? "legacy"}`,
        {preset_version:1,motion:"fly_through",aspect,...(framing ? {framing} : {})}));
      assertEquals(response.status, 202); assertEquals(f.state.events, ["reserve", "POST", "settle"]);
      assertEquals(f.state.posts.length, 1);
      const sent = f.state.posts[0].input;
      assertEquals(sent.aspect, aspect);assertEquals(sent.framing, framing);
      assertEquals(sent.seconds, 5);assertEquals(sent.resolution,"1080p");
      assert(sent.prompt.includes(framing ? "delivery canvas will be added separately" : "garage door and trim colors"));
      // Both output choices use one five-second generation. The output canvas
      // must not change the reservation, bypass it, or add accounting fields.
      const reserve = f.state.rpcs.find((r: {name: string}) => r.name === "app_video_cost_reserve_v2");
      assert(reserve, "reel admission must go through app_video_cost_reserve_v2");
      const args = reserve.args as {p_meta: Record<string, unknown>;p_hold_cents:number};
      if (holdCents === undefined) holdCents = args.p_hold_cents;
      assertEquals(args.p_hold_cents, holdCents);
      assert(Number.isFinite(holdCents) && holdCents! > 0);
      for (const key of Object.keys(args.p_meta)) assert(SQL_ACCOUNTING_META_KEYS.has(key), `accounting metadata key ${key} is not allow-listed in SQL`);
      assertEquals(args.p_meta.aspect, aspect);assertEquals(args.p_meta.motion,"fly_through");assertEquals(args.p_meta.seconds,5);
      assert(!("preset_version" in args.p_meta));
    }
  }
});
// Mirror of the allow-list in public.app_video_cost_reserve (SQL). Keep in sync.
const SQL_ACCOUNTING_META_KEYS = new Set(["tier","upscale_factor","target_fps","interpolated","estimate_cents","output_fps",
  "grounded","seconds","aspect","motion","motion_requested","space_type","route_id","task","unit","price_estimated"]);

async function refusedOrdinaryAerial(f:Awaited<ReturnType<typeof fixture>>, extra:Record<string,unknown>={}) {
  f.reset({ordinary:true});
  const response=await f.handler(req("aerial","ordinary-aerial-coming-soon",extra));
  assertEquals(response.status,503,"Ordinary Aerial must decline before paid admission");
  assertEquals((await response.json()).error,"Aerial intro is Coming soon.");
  assertEquals(f.state.charges,[]);assertEquals(f.state.posts,[]);assertEquals(f.state.events,[]);
  assertEquals(f.state.admitted.size,0);assertEquals(f.state.holds.size,0);assertEquals(f.state.ledger,[]);
}
Deno.test("ordinary Aerial is Coming soon before allowance, dedupe, holds or provider including forged beta claims",async()=>{
  const f=await fixture();
  await refusedOrdinaryAerial(f);
  await refusedOrdinaryAerial(f,{is_admin:true,beta:true,sponsored_unlimited:true,plan:"team"});
  f.reset({ordinary:true});
  const original=req("aerial");const headers=new Headers(original.headers);headers.set("X-Beta","true");headers.set("X-Admin","true");
  assertEquals((await f.handler(new Request(original,{headers}))).status,503);
  assertEquals(f.state.posts,[]);assertEquals(f.state.charges,[]);
});
Deno.test("Aerial private beta uses fresh writable content and actor billing sponsorship, retaining financial admission",async()=>{
  const f=await fixture();
  f.reset({ordinary:true,contentOrg:"agent-private",billingOrg:"existing-sponsor",privateGrant:true});
  assertEquals((await f.handler(req("aerial","existing-private-beta",{listing_id:"owned-listing"}))).status,202);
  assertEquals(f.state.access,{actor:"actor-synthetic",preferred:undefined,listing:"owned-listing",write:true});
  assertEquals(f.state.billing,{org:"agent-private",actor:"actor-synthetic"});
  assert(f.state.grantReads.every((row:any)=>row.args.p_org==="existing-sponsor"));
  assertEquals(f.state.sourceOrgId,"agent-private");assertEquals(f.state.charges.length,1);
  assertEquals(f.state.events,["reserve","POST","settle"]);assertEquals(f.state.ledger.length,1);
  f.reset({ordinary:true,privateGrant:true,reserveError:true});
  assertEquals((await f.handler(req("aerial"))).status,402);assertEquals(f.state.posts,[]);
});
Deno.test("Aerial grants require strict current truth, and outages or revoked scope cannot admit paid work",async()=>{
  const f=await fixture();
  for(const options of [
    {ordinary:true,masterGrant:"true",privateGrant:1},
    {ordinary:true,masterGrant:{active:true},privateGrant:null},
    {ordinary:true,grantThrow:true},{ordinary:true,grantError:true},
    {ordinary:true,privateGrant:true,accessDenied:true},
    {ordinary:true,privateGrant:true,billingDenied:true},
    {ordinary:true,privateGrant:true,identityDenied:true},
  ]){
    f.reset(options);const old=console.error;console.error=()=>{};
    try{const response=await f.handler(req("aerial"));assert([401,403,503].includes(response.status));assertEquals(f.state.posts,[]);assertEquals(f.state.charges,[]);assertEquals(f.state.events,[]);}
    finally{console.error=old;}
  }
});
Deno.test("Coming-soon Aerial does not gate ordinary Reel or source-video tools",async()=>{
  const f=await fixture();for(const route of ["drone","reel-clip"]as const){f.reset({ordinary:true});assertEquals((await f.handler(req(route))).status,202);assertEquals(f.state.posts.length,1);}
});
Deno.test("compiled omitted Aerial launch gate is caught before any ordinary paid dispatch",async()=>{
  const mutant=await fixture(false,false,false,false,true);
  await assertRejects(()=>refusedOrdinaryAerial(mutant),Error,"Ordinary Aerial must decline before paid admission");
  assertEquals(mutant.state.posts.length,1);assertEquals(mutant.state.charges.length,1);
});

Deno.test("background actual reel route saves signedaccepted receipt withrouteroff evenifledger/provenance reconciliationisdown",async()=>{const f=await fixture();f.reset({background:true,ordinary:true,routerOn:false,settleError:true,provenanceError:true});const r=await f.handler(req('reel-clip','background-source-op',{preset_version:1,framing:'preserve_photo',aspect:'16:9',motion:'push_in'}));assert(r.status>=500);assertEquals(f.state.posts.length,1);assertEquals(f.state.holds.size,1);assertEquals(f.state.accepted.request_id,'accepted-provider-id');assertEquals(f.state.accepted.model_id,f.state.posts[0].step.model);assert(f.state.accepted.status_url.includes('?job='));assert(f.state.events.indexOf('signed-worker-receipt')<f.state.events.indexOf('saved-accepted-receipt'));assert(f.state.events.indexOf('saved-accepted-receipt')<f.state.events.indexOf('worker-provenance'));assertEquals(f.state.refunds,0);});

Deno.test("actual ordinary saved profile uses exact same210c funded model for both formats and no owner grant",async()=>{
 const f=await fixture();for(const aspect of["16:9","9:16"]as const){f.reset({ordinary:true});
 const worker={user:{id:"actor-synthetic",is_anonymous:false},listing:"listing-synthetic",targetAspect:aspect,qualityProfile:"fal-kling3-4k-v1",authorize:async()=>{},accepted:async()=>{},provenance:async()=>({id:"owned-provenance",recorded:true,disclosure:"AI motion"})};
 const response=await f.handler(req("reel-clip","normal-profile-"+aspect,{preset_version:1,motion:"push_in",framing:"preserve_photo",aspect}),worker);
 assertEquals(response.status,202);assertEquals(f.state.posts.length,1);assertEquals(f.state.posts[0].step.model,"fal-ai/kling-video/v3/4k/image-to-video");assertEquals(f.state.posts[0].input.extra.property_video_quality_profile,"fal-kling3-4k-v1");
 assertEquals(f.state.ledger[0].p_hold_cents,210);assertEquals(f.state.ledger[0].p_unit_cost_cents,42);assertEquals(f.state.profileReads,2);assertEquals(f.state.oldLedger,0);
 }
});
Deno.test("new profile route revocation refuses before HTTP and preserves known-no-dispatch refund rules",async()=>{
 const f=await fixture();for(const fault of["profileUnavailable","profileRevoked"]){f.reset({ordinary:true,[fault]:true});
 const worker={user:{id:"actor-synthetic",is_anonymous:false},listing:"listing-synthetic",targetAspect:"9:16",qualityProfile:"fal-kling3-4k-v1",authorize:async()=>{},accepted:async()=>{},provenance:async()=>({})};
 const r=await f.handler(req("reel-clip","profile-refused-"+fault,{preset_version:1,motion:"push_in",framing:"preserve_photo",aspect:"9:16"}),worker);
 assert(r.status>=400);assertEquals(f.state.posts.length,0);assertEquals(f.state.refunds,1);assertEquals(f.state.holds.size,0);assertEquals(f.state.ledger.length,0);
 }
});

async function directPropertyOracle(f:any){
 f.reset({ordinary:true});
 const r=await f.handler(req("reel-clip","direct-source-operation",{listing_id:"fa850000-0000-4000-8000-000000000002",source_asset_id:"fa850000-0000-4000-8000-000000000003",space_type:"real_estate"}));
 assertEquals(r.status,202);const body=await r.json();assertEquals(body.request_id,"accepted-provider-id");assertEquals(body.source_bound,true);assertEquals(body.provenance,{id:"fa850000-0000-4000-8000-000000000001",recorded:true});
 assertEquals(f.state.posts.length,1);assertEquals(f.state.ledger.length,1);assertEquals(f.state.refunds,0);
 assertEquals(f.state.rpcs.filter((x:any)=>x.name==="record_direct_property_video_source").length,1);
 assert(!f.state.rpcs.some((x:any)=>x.name==="bind_property_video_source"));assert(f.state.legacyProvenanceCalls===0);
 assert(f.state.events.indexOf("retained-accepted")<f.state.events.indexOf("direct-source-provenance"));
 const audit=f.state.rpcs.find((x:any)=>x.name==="record_direct_property_video_source").args;
 assertEquals(audit.p_key,"direct-source-operation");assertEquals(audit.p_request,body.request_id);assertEquals(audit.p_sha256,"a".repeat(64));
}
Deno.test("actual direct property reel uses atomic provenance after one accepted paid dispatch",async()=>{await directPropertyOracle(await fixture());});
Deno.test("compiled actual legacy-writer regression fails direct paid-source oracle",async()=>{await assertRejects(async()=>directPropertyOracle(await fixture(false,false,false,false,false,true)),Error,"Values are not equal");});
Deno.test("actual accepted direct property reel remains202 when atomic audit fails, never retries or legacy-dedupes",async()=>{
 for(const options of[{sourceAuditThrow:true},{sourceAuditError:true},{sourceAuditReply:{bound:true,request_id:"other-request",provenance_id:"fa850000-0000-4000-8000-000000000001",disclosure:"wrong request"}}]){
  const f=await fixture();f.reset({ordinary:true,...options});const r=await f.handler(req("reel-clip","direct-source-failure",{listing_id:"fa850000-0000-4000-8000-000000000002",source_asset_id:"fa850000-0000-4000-8000-000000000003"}));
  assertEquals(r.status,202);const body=await r.json();assertEquals(body.request_id,"accepted-provider-id");assertEquals(body.source_bound,false);assertEquals(body.provenance,{id:null,recorded:false,reason:"source_audit_unavailable"});
  assertEquals(f.state.posts.length,1);assertEquals(f.state.ledger.length,1);assertEquals(f.state.refunds,0);assert(f.state.legacyProvenanceCalls===0);assert(!JSON.stringify(body).includes("private-audit"));
 }
});
Deno.test("actual non-property direct reel keeps legacy provenance and background property reel keeps worker provenance",async()=>{
 const f=await fixture();f.reset({ordinary:true});assertEquals((await f.handler(req("reel-clip","direct-unbound-operation"))).status,202);assert(f.state.legacyProvenanceCalls>0);assert(!f.state.rpcs.some((x:any)=>x.name==="record_direct_property_video_source"));
 f.reset({ordinary:true,background:true});const r=await f.handler(req("reel-clip","worker-source-operation",{listing_id:"fa850000-0000-4000-8000-000000000002",source_asset_id:"fa850000-0000-4000-8000-000000000003"}));
 assertEquals(r.status,202);assert(f.state.events.includes("worker-provenance"));assert(!f.state.rpcs.some((x:any)=>x.name==="record_direct_property_video_source"));assertEquals(f.state.rpcs.filter((x:any)=>x.name==="bind_property_video_source").length,1);
});
