// POST /ai-video/drift on the direct in-app route: `clip_used` decides whether a
// clip the judge failed is refunded.
//
// Owner decision, 12 Nov 2026: the check against the photo is advisory. iOS
// build 148 keeps a failed clip in the video and says so with `clip_used: true`;
// that clip stays charged. Build 147 sends no such field, discards a failed clip
// and must keep the retry and the allowance refund exactly as before.
//
// The production route slice runs unchanged against closed boundaries: a
// scripted judge, a recording ledger, a recording refund, a recording
// retry-grant limiter and a recording check journal. No provider, database or
// network is reached.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseDriftVerdict } from "../_shared/drift.ts";

const org = "a0730101-0000-4000-8000-000000000001";
const actor = "a0730102-0000-4000-8000-000000000002";
const listing = "a0730103-0000-4000-8000-000000000003";
const provenance = "a0730106-0000-4000-8000-000000000006";
const asset = "a0730107-0000-4000-8000-000000000007";
const requestID = "fixture-direct-reel-clip";
const sourceB64 = btoa("exact prepared source JPEG bytes");
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const provenanceSource = await Deno.readTextFile(
  new URL("../_shared/provenance.ts", import.meta.url),
);
const functionBody = (name: string, text = source) => {
  const match = new RegExp(`(?:export )?(?:async )?function ${name}\\(`).exec(
    text,
  );
  assert(match, `${name} production anchor missing`);
  const end = text.indexOf("\n}\n", match.index);
  assert(end > match.index, `${name} closing anchor missing`);
  return text.slice(match.index, end + 3).replace(/^export /, "");
};
const statement = (name: string) => {
  const found = source.match(new RegExp(`const ${name}[^;]*;`));
  assert(found, `${name} production constant missing`);
  return found[0];
};
const routeStart = source.indexOf(
  '    if (req.method === "POST" && seg.length === 1 && seg[0] === "drift")',
);
const routeEnd = source.indexOf(
  "    // ---- GET /ai-video/status ----",
  routeStart,
);
assert(routeStart > 0 && routeEnd > routeStart);
type Row = Record<string, any>;
const dataModule = (s: string) =>
  "data:application/typescript;base64," +
  btoa(String.fromCharCode(...new TextEncoder().encode(s)));

const compiled = await import(dataModule(`
    import {HttpError,assert,json,readJsonLimited,respondError} from ${
  JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
};
    import {DRIFT_FRAME_POSITIONS,DRIFT_MAX_FRAMES,DRIFT_PASS_SCORES,DRIFT_TASK,parseDriftVerdict,decideDriftAction,driftBlock,driftLineageKey,driftPasses,failedCategories,type DriftVerdict,type DriftFramePosition} from ${
  JSON.stringify(new URL("../_shared/drift.ts", import.meta.url).href)
};
    import {AERIAL_MOTIONS,AERIAL_MOTION_TEXT,REEL_MOTION_TEXT,parseReelMotion,type AerialMotion} from ${
  JSON.stringify(new URL("./motion.ts", import.meta.url).href)
};
    import {MAX_DRIFT_FRAME_B64_CHARS,MAX_DRIFT_REQUEST_BODY_BYTES,MAX_DRIFT_SOURCE_B64_CHARS,validateExtendedReelSource} from ${
  JSON.stringify(new URL("./drift-input.ts", import.meta.url).href)
};
    type GenKind="reel"|"aerial"|"drone"|"declutter";
    type PaidAiCaller={id:string};type DriftBody=Record<string,any>;type JudgeOutcome=any;
    interface DriftImage{b64:string;mime:string};interface DriftFrame extends DriftImage{at:DriftFramePosition};
    ${statement("ALLOWED_IMAGE_MIMES")}
    ${statement("MAX_DRIFT_IMAGE_B64_CHARS")}
    ${statement("MAX_DRIFT_BODY_BYTES")}
    ${statement("DRIFT_MAX_PER_WINDOW")}
    ${statement("DRIFT_WINDOW_SECONDS")}
    ${statement("DRIFT_LINEAGE_WINDOW_SECONDS")}
    ${statement("SPACE_TYPES")}
    type SpaceType=typeof SPACE_TYPES[number];
    const SCENE_NOUN={real_estate:"home",venue:"event venue",restaurant:"restaurant",retail:"store",fitness:"fitness studio",other:"space"};
    const UUID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    ${functionBody("optionalUuid", provenanceSource)}
    ${functionBody("cleanRequestId")}
    ${functionBody("requireDriftImage")}
    ${functionBody("cleanDriftFrames")}
    ${functionBody("spaceTypeOf")}
    ${functionBody("driftMotionText")}
    export function make(deps:any){
      const adminClient=()=>deps.admin,orgForUser=deps.orgForUser,contentOrgForUser=deps.contentOrg;const rpc=(name:string,args:any)=>adminClient().rpc(name,args);
      const requireLibraryWrite=deps.libraryWrite,assertPaidAiIdentity=deps.paidIdentity;
      const preferredOrg=(req:Request)=>req.headers.get("x-org-id")||undefined;
      const durableRateLimit=deps.rate;
      // No saved verdict exists for this clip: every call is a first judgement.
      const cachedDriftResponse=async(..._args:any[])=>null;
      const beginDriftCheck=deps.begin,finishDriftCheck=deps.finish,completeFundingOperation=deps.complete;
      const judgeDrift=deps.judge,driftRoutingPlan=async(..._args:any[])=>({});
      const refundRejectedClipAllowance=deps.refund,recordRoutedAiCost=deps.cost,stampProvenanceQc=deps.stamp;
      ${functionBody("guardDriftCheck")}
      return async(req:Request,worker?:any)=>{const user={id:deps.actor},seg=["drift"];try{${
  source.slice(routeStart, routeEnd)
}\nthrow new HttpError(405,"missing route");}catch(error){return respondError(error);}};
    }
  `));

type Judged = "fail" | "pass" | "unavailable";
function verdictFor(judged: Judged) {
  if (judged === "unavailable") return parseDriftVerdict("");
  const passing = judged === "pass";
  return parseDriftVerdict(JSON.stringify({
    architecture: passing ? 98 : 60,
    contents: 96,
    additions: 99,
    artifacts: 95,
    same_room: 99,
    confidence: 0.93,
    verdict: passing ? "pass" : "fail",
    reason: passing
      ? "The original house remains unchanged."
      : "The generated garage door changes the original house.",
  }));
}

function fixture(judged: Judged = "fail", options: { grant?: boolean } = {}) {
  const rates: string[] = [],
    refunds: Row[] = [],
    ledger: Row[] = [],
    stamps: Row[] = [],
    finished: Row[] = [],
    completed: Row[] = [];
  let judgeCalls = 0;
  const step = {
    provider: "anthropic",
    model: "claude-fixture",
    task: "judge.qc_drift",
    route_id: "route-fixture",
    unit: "call",
    unit_cents: 1.3,
  };
  const funding = { requestKey: "drift-check:fixture", rpc: async () => ({ data: true, error: null }) };
  const handler = compiled.make({
    admin: { rpc: async () => { throw Error("No direct database write is expected"); } },
    actor,
    orgForUser: async () => org,
    contentOrg: async () => org,
    libraryWrite: async () => {},
    paidIdentity: async () => {},
    rate: async (key: string) => {
      rates.push(key);
      // The burst limiter always admits; the per-photo retry grant is scripted.
      return key.startsWith("aidriftlin:") ? options.grant !== false : true;
    },
    begin: async () => ({ id: "check-fixture", funding, replay: null }),
    finish: async (_rpc: unknown, who: string, where: string, id: string, action: string, result: Row | null) => {
      finished.push({ who, where, id, action, result });
    },
    complete: async (_funding: unknown, result: Row) => { completed.push(result); },
    judge: async () => {
      judgeCalls++;
      const unavailable = judged === "unavailable";
      return {
        verdict: verdictFor(judged),
        calls: unavailable ? [] : [{ step, escalated: false, stage: "qc" }],
        step: unavailable ? null : step,
        escalated: false,
        sourceHash: "f".repeat(64),
      };
    },
    refund: async (where: string, kind: string, request: string, who: string) => {
      refunds.push({ where, kind, request, who });
      return { refunded: true, reason: "Original allowance restored" };
    },
    cost: async (_admin: unknown, row: Row) => { ledger.push(row); return { recorded: true }; },
    stamp: async (where: string, id: string, qc: Row) => { stamps.push({ where, id, qc }); return true; },
  });
  const base: Row = {
    request_id: requestID,
    kind: "reel",
    listing_id: listing,
    source_b64: sourceB64,
    source_mime: "image/jpeg",
    frames: ["first", "middle", "last"].map((at) => ({ at, b64: btoa("decoded-" + at), mime: "image/jpeg" })),
    seconds: 5,
    attempt: 0,
    provenance_id: provenance,
    asset_id: asset,
  };
  return {
    rates, refunds, ledger, stamps, finished, completed,
    judgeCalls: () => judgeCalls,
    invoke: async (over: Row = {}, worker?: Row) => {
      const response = await handler(
        new Request("https://fixture.invalid/ai-video/drift", {
          method: "POST",
          headers: { "content-type": "application/json", "x-org-id": org },
          body: JSON.stringify({ ...base, ...over }),
        }),
        worker,
      );
      return { status: response.status, body: await response.json() as Row };
    },
  };
}
const grantKeys = (rates: string[]) => rates.filter((key) => key.startsWith("aidriftlin:"));

Deno.test("build 147 (no clip_used): a failed first clip is retried once and its allowance is refunded, as before", async () => {
  for (const sent of [{}, { clip_used: false }]) {
    const f = fixture("fail");
    const r = await f.invoke(sent);
    assertEquals(r.status, 200);
    assertEquals([r.body.drift.status, r.body.drift.action, r.body.drift.publishable], ["fail", "retry", false]);
    assertEquals(r.body.charge, { allowance_refunded: true, note: "Original allowance restored", retry_costs_another_clip: false });
    assertEquals("enforcement" in r.body, false, "an enforced verdict carries no advisory mark");
    assertEquals(f.refunds, [{ where: org, kind: "reel", request: requestID, who: actor }]);
    assertEquals(grantKeys(f.rates).length, 1, "the one retry grant for this photo is consumed");
    assertEquals(f.ledger.length, 1);
    const meta = f.ledger[0].meta;
    assertEquals([meta.verdict, meta.action, meta.publishable, meta.attempt, meta.allowance_refunded], ["fail", "retry", false, 0, true]);
    assertEquals("enforcement" in meta || "clip_used" in meta, false);
    assertEquals(f.stamps.length, 1);
    assertEquals("enforcement" in f.stamps[0].qc, false);
    assertEquals(f.finished.map((x) => x.action), ["retry"]);
  }
});

Deno.test("build 147 (no clip_used): a failed second clip is refused and refunded, as before", async () => {
  const f = fixture("fail");
  const r = await f.invoke({ attempt: 1 });
  assertEquals([r.status, r.body.drift.action, r.body.drift.publishable], [200, "refuse", false]);
  assertEquals(r.body.charge.allowance_refunded, true);
  assertEquals("enforcement" in r.body, false);
  assertEquals(f.refunds.length, 1);
  assertEquals(grantKeys(f.rates), [], "a client that says this is already the retry is believed");
  assertEquals(f.ledger[0].meta.allowance_refunded, true);
  assert(String(r.body.drift.message).includes("Use the still"), "the enforced sentence still offers the still photo");
});

Deno.test("build 148 (clip_used true): a failed clip is used, stays charged and is recorded as advisory", async () => {
  for (const attempt of [0, 1]) {
    const f = fixture("fail");
    const r = await f.invoke({ clip_used: true, attempt });
    assertEquals(r.status, 200);
    // The judge's own finding is passed on unchanged: failed and not publishable.
    assertEquals([r.body.drift.status, r.body.drift.action, r.body.drift.publishable, r.body.drift.verdict], ["fail", "refuse", false, "fail"]);
    assertEquals("retry" in r.body.drift, false, "no second generation is offered");
    assertEquals(r.body.enforcement, "advisory");
    assertEquals(r.body.charge, {
      allowance_refunded: false,
      note: "this clip is used in your video and stays charged to your plan as usual",
      retry_costs_another_clip: false,
    });
    assert(String(r.body.drift.message).includes("the clip is still in your video"));
    assertEquals(f.refunds, [], "a clip the app uses is never refunded");
    assertEquals(grantKeys(f.rates), [], "no retry grant is consumed for a clip that is used");
    assertEquals(f.ledger.length, 1, "the judge call is still paid for and recorded");
    const meta = f.ledger[0].meta;
    assertEquals([meta.verdict, meta.action, meta.publishable, meta.attempt, meta.allowance_refunded, meta.enforcement, meta.clip_used],
      ["fail", "refuse", false, attempt, false, "advisory", true]);
    assertEquals(f.ledger[0].feature, "qc");
    assertEquals(f.stamps.length, 1);
    assertEquals([f.stamps[0].id, f.stamps[0].qc.verdict, f.stamps[0].qc.action, f.stamps[0].qc.publishable, f.stamps[0].qc.enforcement],
      [provenance, "fail", "refuse", false, "advisory"]);
    assertEquals(f.finished.map((x) => x.action), ["refuse"]);
    assertEquals(f.completed.length, 1);
    assertEquals(f.completed[0].enforcement, "advisory", "the saved reply a later replay returns is the advisory one");
  }
});

Deno.test("clip_used true changes nothing for a clip that passed or could not be checked", async () => {
  const passed = fixture("pass");
  const p = await passed.invoke({ clip_used: true });
  assertEquals([p.status, p.body.drift.action, p.body.drift.publishable, p.body.enforcement], [200, "accept", true, "advisory"]);
  assertEquals(p.body.charge, { allowance_refunded: false, note: "this clip was charged to your plan as usual", retry_costs_another_clip: false });
  assertEquals(passed.refunds, []);
  for (const sent of [{}, { clip_used: true }]) {
    const held = fixture("unavailable");
    const h = await held.invoke(sent);
    assertEquals([h.status, h.body.drift.action, h.body.drift.publishable], [200, "hold", false]);
    assertEquals(h.body.charge.allowance_refunded, false);
    assertEquals(held.refunds, [], "a check that could not run never refunds, in either mode");
    assertEquals(grantKeys(held.rates), []);
    assertEquals(held.ledger, [], "no judge answered, so there is no judge cost row");
  }
});

Deno.test("clip_used must be a real boolean and is refused before anything is spent", async () => {
  for (const clip_used of ["true", 1, "yes", {}]) {
    const f = fixture("fail");
    const r = await f.invoke({ clip_used });
    assertEquals(r.status, 400);
    assertEquals(f.rates, [], "a malformed body does not spend a limiter token");
    assertEquals(f.judgeCalls(), 0);
    assertEquals([f.refunds, f.ledger, f.stamps, f.finished], [[], [], [], []]);
  }
  // null reads as absent: today's enforced behaviour.
  const f = fixture("fail");
  const r = await f.invoke({ clip_used: null });
  assertEquals([r.status, r.body.drift.action, f.refunds.length], [200, "retry", 1]);
});

Deno.test("the property-video worker stays advisory without the client field and is not marked clip_used", async () => {
  const f = fixture("fail");
  const r = await f.invoke({}, { advisoryQuality: true, listing });
  assertEquals([r.status, r.body.drift.action, r.body.enforcement], [200, "refuse", "advisory"]);
  assertEquals(f.refunds, []);
  assertEquals(f.ledger[0].meta.enforcement, "advisory");
  assertEquals("clip_used" in f.ledger[0].meta, false);
});
