// Source-bound POST /drift recovery: the production branch and ownership/cache
// helper execute against closed auth/DB boundaries. The judge, paid admission,
// ledger writes and refunds are traps: a saved verdict must use none of them.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { driftLineageKey } from "../_shared/drift.ts";

const org = "a0620101-0000-4000-8000-000000000001";
const actor = "a0620102-0000-4000-8000-000000000002";
const listing = "a0620103-0000-4000-8000-000000000003";
const reservation = "a0620104-0000-4000-8000-000000000004";
const ledgerID = "a0620105-0000-4000-8000-000000000005";
const provenance = "a0620106-0000-4000-8000-000000000006";
const asset = "a0620107-0000-4000-8000-000000000007";
const foreign = "a0620199-0000-4000-8000-000000000099";
const requestID = "fixture-existing-paid-reel";
const sourceB64 = btoa("identical original prepared JPEG bytes");
const sourceHash = await driftLineageKey(sourceB64);
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
type Mutation =
  | "source"
  | "actor"
  | "org"
  | "listing"
  | "access"
  | "ledger"
  | "reuse";
const dataModule = (s: string) =>
  "data:application/typescript;base64," +
  btoa(String.fromCharCode(...new TextEncoder().encode(s)));
function replace(text: string, before: string, after: string, name: string) {
  assertEquals(text.split(before).length, 2, `${name} mutation anchor changed`);
  return text.replace(before, after);
}

async function compiled(mutation?: Mutation) {
  let cache = functionBody("cachedDriftResponse");
  let route = source.slice(routeStart, routeEnd);
  // Each mutation is a unique expression in the final production helper;
  // no copied policy or synthetic alternate cache implementation is tested.
  if (mutation) ({ cache, route } = mutate(mutation, cache, route));
  return await import(dataModule(`
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
    type PaidAiCaller={id:string};type DriftBody=Record<string,any>;
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
      const adminClient=()=>deps.admin,orgForUser=deps.orgForUser,contentOrgForUser=deps.contentOrg;
      const requireLibraryWrite=deps.libraryWrite,assertPaidAiIdentity=deps.paidIdentity;
      const preferredOrg=(req:Request)=>req.headers.get("x-org-id")||undefined;
      const durableRateLimit=deps.rate;
      const trap=(name:string)=>async(..._args:any[])=>{deps.traps.push(name);throw new HttpError(500,"Unexpected "+name+" in cached recovery");};
      const fundingContext=trap("funding"),judgeDrift=trap("judge"),driftRoutingPlan=trap("routing");
      const refundRateLimit=trap("refundRate"),refundRejectedClipAllowance=trap("allowanceRefund"),recordRoutedAiCost=trap("costWrite"),stampProvenanceQc=trap("provenanceWrite");
      ${functionBody("guardDriftCheck")}
      ${cache}
      return async(req:Request)=>{const user={id:deps.actor},seg=["drift"];try{${route}\nthrow new HttpError(405,"missing route");}catch(error){return respondError(error);}};
    }
  `));
}

function mutate(
  mutation: Mutation,
  cache: string,
  route: string,
): { cache: string; route: string } {
  if (mutation === "source") {
    cache = replace(
      cache,
      "row.meta?.source_sha256 === sourceHash &&",
      "true &&",
      mutation,
    );
  }
  if (mutation === "actor") {
    cache = replace(cache, '.eq("actor_id", args.actor)', "", mutation);
    cache = replace(
      cache,
      "payment.actor_id === args.actor &&",
      "true &&",
      mutation,
    );
  }
  if (mutation === "org") {
    cache = replace(
      cache,
      '.eq("org_id", args.orgId).eq("actor_id", args.actor)',
      '.eq("actor_id", args.actor)',
      mutation,
    );
    cache = replace(
      cache,
      "payment.org_id === args.orgId &&",
      "true &&",
      mutation,
    );
  }
  if (mutation === "listing") {
    cache = replace(
      cache,
      "(args.listingId === null || args.listingId === allowance.data.listing_id)",
      "true",
      mutation,
    );
  }
  if (mutation === "access") {
    cache = replace(
      cache,
      "await contentOrgForUser(args.actor, args.orgId, listingId, true) === args.orgId",
      "true",
      mutation,
    );
  }
  if (mutation === "ledger") {
    cache = replace(
      cache,
      "const paid = settled.data;",
      `const paid={id:payment.cost_ledger_id,org_id:args.orgId,feature:args.kind,provider:payment.provider,model:payment.model,total_cents:24.3,meta:{app_video_reservation_id:payment.id,request_id:args.requestId,billing_org_id:args.orgId,request_key:payment.idempotency_key,stage:args.kind}};`,
      mutation,
    );
  }
  if (mutation === "reuse") {
    route = replace(
      route,
      "if (cached) return cached;",
      "if (false) return cached;",
      mutation,
    );
  }
  return { cache, route };
}

async function fixture(
  options: {
    verdict?: "pass" | "retry" | "refuse";
    historical?: boolean;
    mutation?: Mutation;
  } = {},
) {
  const action = options.verdict ?? "refuse", passing = action === "pass";
  const qcMeta: Row = {
    kind: "video_drift",
    clip_kind: "reel",
    request_id: requestID,
    source_sha256: sourceHash,
    source_asset_id: options.historical ? null : asset,
    provenance_id: options.historical ? null : provenance,
    scores: {
      architecture: passing ? 98 : 60,
      contents: 96,
      additions: 99,
      artifacts: 95,
      same_room: 99,
    },
    verdict: passing ? "pass" : "fail",
    confidence: 0.93,
    reason: passing
      ? "The original house remains unchanged."
      : "The generated garage door changes the original house.",
    action: passing ? "accept" : action,
    publishable: passing,
    attempt: action === "retry" ? 0 : 1,
    allowance_refunded: !passing,
    frames_judged: 3,
    seconds: 5,
    escalated: false,
  };
  const reservations: Row[] = [{
    id: reservation,
    org_id: org,
    actor_id: actor,
    idempotency_key: "fixture-original-admission",
    feature: "reel",
    provider: "fal",
    model: "seedance-fixture",
    provider_request_id: requestID,
    cost_ledger_id: ledgerID,
    settled_at: "2026-10-12T17:04:00Z",
    released_at: null,
    billing_org_id: org,
    meta: { task: "video.reel_clip" },
  }];
  const allowances: Row[] = [{
    reservation_id: reservation,
    listing_id: listing,
    drift_refunded_at: passing ? null : "2026-10-12T17:04:10Z",
  }];
  const generation: Row = {
    id: ledgerID,
    org_id: org,
    feature: "reel",
    provider: "fal",
    model: "seedance-fixture",
    total_cents: 24.3,
    meta: {
      app_video_reservation_id: reservation,
      request_id: requestID,
      billing_org_id: org,
      request_key: "fixture-original-admission",
      stage: "reel",
    },
  };
  const qc: Row = {
    id: "a0620108-0000-4000-8000-000000000008",
    org_id: org,
    feature: "qc",
    provider: "anthropic",
    model: "claude-fixture",
    total_cents: 1,
    created_at: "2026-10-12T17:04:10Z",
    meta: qcMeta,
  };
  const ledgers: Row[] = [generation, qc];
  const tables: Record<string, Row[]> = {
    app_video_cost_reservations: reservations,
    app_video_allowance_receipts: allowances,
    cost_ledger: ledgers,
    media_provenance: [{
      id: provenance,
      org_id: org,
      listing_id: listing,
      kind: "reel",
      model_id: "seedance-fixture",
    }],
    capture_assets: [{
      id: asset,
      listing_id: listing,
      kind: "photo",
      uploaded: true,
    }],
  };
  const queries: string[] = [],
    traps: string[] = [],
    permissions: string[] = [],
    rates: string[] = [];
  let denied = false,
    identityDenied = false,
    dbFailure: string | null = null,
    resolved = org;
  const admin = {
    from(table: string) {
      assert(table in tables, `unexpected table ${table}`);
      queries.push(table);
      const filters: ((row: Row) => boolean)[] = [];
      const result = () => ({
        data: tables[table].filter((row) => filters.every((f) => f(row))),
        error: dbFailure === table
          ? { message: "closed DB unavailable" }
          : null,
      });
      const field = (row: Row, key: string) =>
        key.startsWith("meta->>") ? row.meta?.[key.slice(7)] : row[key];
      const q: any = {
        select: () => q,
        eq: (key: string, value: unknown) => {
          filters.push((row) => field(row, key) === value);
          return q;
        },
        is: (key: string, value: unknown) => {
          filters.push((row) => field(row, key) === value);
          return q;
        },
        in: (key: string, values: unknown[]) => {
          filters.push((row) => values.includes(field(row, key)));
          return q;
        },
        order: () => q,
        limit: async (n: number) => {
          const r = result();
          return { ...r, data: r.data.slice(0, n) };
        },
        maybeSingle: async () => {
          const r = result();
          return {
            data: r.data.length === 1 ? r.data[0] : null,
            error: r.error ||
              (r.data.length > 1 ? { message: "ambiguous row" } : null),
          };
        },
        then: (yes: any, no: any) => Promise.resolve(result()).then(yes, no),
      };
      return q;
    },
    rpc: async () => {
      traps.push("rpcWrite");
      throw Error("No writes permitted in cached recovery");
    },
  };
  const module = await compiled(options.mutation);
  const handler = module.make({
    admin,
    actor,
    traps,
    orgForUser: async (user: string, preferred: string | undefined) => {
      assertEquals(user, actor);
      if (preferred && preferred !== org) throw Error("foreign org");
      return org;
    },
    libraryWrite: async (_admin: any, user: string, library: string) => {
      permissions.push("library");
      assertEquals([user, library], [actor, org]);
      if (denied) throw Error("current library denied");
    },
    paidIdentity: async (user: { id: string }, library: string) => {
      permissions.push("identity");
      assertEquals([user.id, library], [actor, org]);
      if (identityDenied) throw Error("current identified user denied");
    },
    contentOrg: async (
      user: string,
      preferred: string | undefined,
      listed?: string,
      ..._options: any[]
    ) => {
      permissions.push("listing");
      assertEquals(user, actor);
      if (
        denied || listed !== listing || preferred && preferred !== org
      ) throw Error("current listing denied");
      return resolved;
    },
    rate: async (key: string) => {
      rates.push(key);
      return !key.startsWith("aidriftjob:");
    },
  });
  const base: Row = {
    request_id: requestID,
    kind: "reel",
    listing_id: listing,
    source_b64: sourceB64,
    source_mime: "image/jpeg",
    frames: [{
      at: "first",
      b64: btoa("regenerated-decoder-frame"),
      mime: "image/jpeg",
    }],
    seconds: 5,
    attempt: 1,
    ...(!options.historical
      ? { provenance_id: provenance, asset_id: asset }
      : {}),
  };
  return {
    reservations,
    allowances,
    ledgers,
    generation,
    qc,
    queries,
    traps,
    permissions,
    rates,
    base,
    deny: () => {
      denied = true;
    },
    denyIdentity: () => {
      identityDenied = true;
    },
    dbFailure: (table: string) => {
      dbFailure = table;
    },
    resolveElsewhere: () => {
      resolved = foreign;
    },
    invoke: async (over: Row = {}) =>
      handler(
        new Request("https://fixture.invalid/ai-video/drift", {
          method: "POST",
          headers: { "content-type": "application/json", "x-org-id": org },
          body: JSON.stringify({ ...base, ...over }),
        }),
      ),
  };
}

Deno.test("actual drift recovery replays historical terminal refusal without new judge, generation or refund", async () => {
  const f = await fixture({ historical: true });
  for (let i = 0; i < 3; i++) {
    const response = await f.invoke();
    assertEquals(response.status, 200);
    const value = await response.json();
    assertEquals([
      value.drift.status,
      value.drift.action,
      value.drift.publishable,
    ], ["fail", "refuse", false]);
    assertEquals(value.drift.attempt, 1);
    assertEquals(value.drift.reason, f.qc.meta.reason);
    assertEquals(value.cached, true);
    assertEquals(value.recorded, { ledger: 0, provenance: false });
    assertEquals(value.charge.allowance_refunded, true);
  }
  assertEquals(f.traps, []);
  assert(!f.rates.some((k) => k.startsWith("aidriftjob:")));
  assert(f.permissions.includes("listing"));
  assertEquals(f.reservations.length, 1);
  assertEquals(f.ledgers.length, 2);
  assert(f.allowances[0].drift_refunded_at);
});

for (const verdict of ["pass", "retry", "refuse"] as const) {
  Deno.test(`actual drift recovery preserves existing ${verdict} decision and attempt`, async () => {
    const f = await fixture({ verdict });
    const response = await f.invoke({ attempt: 0 });
    assertEquals(response.status, 200);
    const value = await response.json();
    assertEquals(value.drift.action, verdict === "pass" ? "accept" : verdict);
    assertEquals(value.drift.publishable, verdict === "pass");
    assertEquals(value.drift.attempt, verdict === "retry" ? 0 : 1);
    assertEquals(f.traps, []);
    assert(!f.rates.some((k) => k.startsWith("aidriftjob:")));
  });
}

Deno.test("changed decoded frames cannot buy a second judgement for the same original paid clip", async () => {
  const f = await fixture();
  const response = await f.invoke({
    frames: [{
      at: "last",
      b64: btoa("different decoded frame"),
      mime: "image/jpeg",
    }],
  });
  assertEquals(response.status, 200);
  assertEquals((await response.json()).drift.action, "refuse");
  assertEquals(f.traps, []);
});

Deno.test("historical missing provenance can validate new same-listing context without stamping it", async () => {
  const f = await fixture({ historical: true });
  const response = await f.invoke({
    provenance_id: provenance,
    asset_id: asset,
  });
  assertEquals(response.status, 200);
  assertEquals((await response.json()).recorded, {
    ledger: 0,
    provenance: false,
  });
  assertEquals(f.traps, []);
});

Deno.test("two original escalation charges replay the one final verdict and final judge identity", async () => {
  const f = await fixture();
  f.ledgers.push({
    ...f.qc,
    id: foreign,
    model: "escalated-fixture",
    meta: { ...f.qc.meta, escalated: true },
  });
  const response = await f.invoke();
  assertEquals(response.status, 200);
  const value = await response.json();
  assertEquals(value.drift.model, "escalated-fixture");
  assertEquals(value.drift.escalated, true);
  assertEquals(value.drift.action, "refuse");
  assertEquals(f.traps, []);
});

Deno.test("guest or revoked identity is refused before stored ledger access", async () => {
  const f = await fixture();
  f.denyIdentity();
  assert((await f.invoke()).status >= 400);
  assertEquals(f.queries, []);
  assertEquals(f.traps, []);
});

Deno.test("a duplicate without a durable verdict remains stopped before another judge or charge", async () => {
  const f = await fixture();
  f.ledgers.splice(1, 1);
  assertEquals((await f.invoke()).status, 409);
  assertEquals(f.traps, []);
});

const denials: [
  string,
  (f: Awaited<ReturnType<typeof fixture>>) => void,
  Row?,
][] = [
  ["foreign actor", (f) => {
    f.reservations[0].actor_id = foreign;
  }],
  ["foreign generation library", (f) => {
    f.reservations[0].org_id = foreign;
  }],
  ["foreign allowance listing", (f) => {
    f.allowances[0].listing_id = foreign;
  }],
  ["different original source", () => {}, {
    source_b64: btoa("different original JPEG"),
  }],
  ["different declared listing", () => {}, { listing_id: foreign }],
  ["malformed declared listing", () => {}, { listing_id: "not-a-uuid" }],
  ["different clip kind", () => {}, { kind: "aerial" }],
  ["different provenance", () => {}, { provenance_id: foreign }],
  ["different source asset", () => {}, { asset_id: foreign }],
  ["released generation", (f) => {
    f.reservations[0].released_at = "2026-10-12T17:04:11Z";
  }],
  ["unsettled generation", (f) => {
    f.reservations[0].settled_at = null;
    f.reservations[0].cost_ledger_id = null;
  }],
  ["missing paid ledger", (f) => {
    f.ledgers.splice(0, 1);
  }],
  ["mismatched paid request", (f) => {
    f.generation.meta.request_id = "other-request";
  }],
  ["foreign paid ledger", (f) => {
    f.generation.org_id = foreign;
  }],
  ["mismatched paid reservation", (f) => {
    f.generation.meta.app_video_reservation_id = foreign;
  }],
  ["mismatched paid request key", (f) => {
    f.generation.meta.request_key = "other-admission";
  }],
  ["mismatched paid stage", (f) => {
    f.generation.meta.stage = "aerial";
  }],
  ["mismatched paid provider", (f) => {
    f.generation.provider = "other-provider";
  }],
  ["mismatched paid model", (f) => {
    f.generation.model = "other-model";
  }],
  ["mismatched paid billing library", (f) => {
    f.generation.meta.billing_org_id = foreign;
  }],
  ["zero provider payment", (f) => {
    f.generation.total_cents = 0;
  }],
  ["ambiguous generation receipt", (f) => {
    f.reservations.push({ ...f.reservations[0] });
  }],
  ["current library permission withdrawn", (f) => {
    f.deny();
  }],
  ["current content scope changed", (f) => {
    f.resolveElsewhere();
  }],
  ["stored verdict missing category", (f) => {
    delete f.qc.meta.scores.same_room;
  }],
  ["stored action disagrees with scores", (f) => {
    f.qc.meta.action = "accept";
  }],
  ["stored publishable disagrees with failure", (f) => {
    f.qc.meta.publishable = true;
  }],
  ["conflicting stored judgments", (f) => {
    f.ledgers.push({
      ...f.qc,
      id: foreign,
      meta: { ...f.qc.meta, reason: "Different judgment" },
    });
  }],
  ["too many stored judgments", (f) => {
    f.ledgers.push({ ...f.qc, id: foreign }, { ...f.qc, id: asset });
  }],
  ["stored invalid confidence", (f) => {
    f.qc.meta.confidence = 1.1;
  }],
  ["stored invalid attempt", (f) => {
    f.qc.meta.attempt = 4;
  }],
  ["stored invalid frame count", (f) => {
    f.qc.meta.frames_judged = 0;
  }],
];
for (const [name, change, over] of denials) {
  Deno.test(`actual drift recovery refuses ${name} without vendor work or financial writes`, async () => {
    const f = await fixture();
    change(f);
    const response = await f.invoke(over);
    assert(
      response.status >= 400,
      `unsafe ${name} returned ${response.status}`,
    );
    assertEquals(f.traps, []);
  });
}

for (
  const table of [
    "cost_ledger",
    "app_video_cost_reservations",
    "app_video_allowance_receipts",
  ]
) {
  Deno.test(`actual drift recovery fails closed on ${table} read failure`, async () => {
    const f = await fixture();
    f.dbFailure(table);
    const response = await f.invoke();
    assertEquals(response.status, 503);
    assertEquals(f.traps, []);
  });
}

for (
  const mutation of [
    "source",
    "actor",
    "org",
    "listing",
    "access",
    "ledger",
    "reuse",
  ] as const
) {
  Deno.test(`negative control detects removed drift recovery ${mutation} fence`, async () => {
    const f = await fixture({ mutation });
    const change = denials.find(([name]) =>
      name === ({
        source: "different original source",
        actor: "foreign actor",
        org: "foreign generation library",
        listing: "different declared listing",
        access: "current content scope changed",
        ledger: "missing paid ledger",
        reuse: "different original source",
      }[mutation])
    );
    assert(change);
    if (mutation !== "reuse") change[1](f);
    const response = await f.invoke(mutation === "reuse" ? {} : change[2]);
    // A removed authority fence must visibly leak the cached verdict; a removed
    // reuse branch must visibly take the duplicate refusal path instead.
    if (mutation === "reuse") {
      assertEquals(response.status, 409);
      assert(f.rates.some((k) => k.startsWith("aidriftjob:")));
    } else {
      assertEquals(response.status, 200);
      assertEquals((await response.json()).drift.action, "refuse");
    }
    assertEquals(f.traps, []);
  });
}
