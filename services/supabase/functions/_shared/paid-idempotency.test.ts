import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import { requiredIdempotencyKey } from "./idempotency.ts";
import { fundingContext } from "./funded-serving.ts";

Deno.test("paid key validation preserves native UUID/hash keys and rejects absent or malformed keys", () => {
  for (
    const key of [
      crypto.randomUUID(),
      `drone:${crypto.randomUUID()}`,
      `k:${"a".repeat(64)}`,
      "x".repeat(8),
      "x".repeat(128),
    ]
  ) {
    assertEquals(
      requiredIdempotencyKey({
        headers: new Headers({ "idempotency-key": key }),
      }),
      key,
    );
  }
  for (
    const key of [
      null,
      "",
      "x".repeat(7),
      "x".repeat(129),
      "invalid key",
      " leading-key",
      "trailing-key ",
      "key\tinside",
      "nonascii-é-key",
    ]
  ) {
    let rejected = false;
    try {
      requiredIdempotencyKey({
        headers: { get: () => key } as unknown as Headers,
      });
    } catch (error) {
      rejected = error instanceof HttpError && error.status === 400;
    }
    assert(rejected, `Key was not rejected: ${JSON.stringify(key)}`);
  }
});

const routes = [
  ["ai-photo", "guardEdit"],
  ["ai-video", "guardGenerate"],
  ["ai-chapters", "guardChapters"],
  ["ai-voice", "guardTTS"],
] as const;

// Execute the current production guard body, replacing only its external
// authorization/DB/meter boundaries. This also detects a disconnected validator.
async function loadGuard(endpoint: string, name: string, mutant = false) {
  const source = await Deno.readTextFile(
    new URL(`../${endpoint}/index.ts`, import.meta.url),
  );
  const start = source.indexOf(`async function ${name}(`);
  assert(start >= 0);
  let body = source.slice(start, source.indexOf("\n}\n", start) + 3).replace(
    `async function ${name}`,
    `export async function ${name}`,
  );
  if (mutant) {
    body = body.replace(
      "requiredIdempotencyKey(req)",
      'req.headers.get("idempotency-key") ?? "missing-mutant-key"',
    );
  }
  const fixture = `
    import {HttpError} from ${
    JSON.stringify(new URL("./http.ts", import.meta.url).href)
  };
    import {requiredIdempotencyKey} from ${
    JSON.stringify(new URL("./idempotency.ts", import.meta.url).href)
  };
    type EditCharge=any;type Charge=any;type GenerateCharge=any;type GenKind=any;
    const EDIT_MAX_PER_WINDOW=40,EDIT_WINDOW_SECONDS=300,GEN_MAX_PER_WINDOW=12,GEN_WINDOW_SECONDS=300,BURST_MAX_PER_WINDOW=10,BURST_WINDOW_SECONDS=300,TTS_MAX_PER_WINDOW=20,TTS_WINDOW_SECONDS=300,MONTH_SECONDS=2592000;
    export const calls:string[]=[];const seen=new Set<string>();
    const orgForUser=async(..._args:any[])=>"synthetic-org";
    const preferredOrg=(_req:Request)=>undefined;
    const requireEditorRole=orgForUser;
    const assertPaidAiIdentity=async(..._args:any[])=>{};
    const entitlementForCharge=async(..._args:any[])=>({plan:"team",photo_edits_per_month:400,renders_per_month:400,reels_per_month:400,cogs_ceiling_cents:6000});
    const quotaError=(..._args:any[])=>new HttpError(402,"quota");
    const capFor=(..._args:any[])=>400;const labelFor=(..._args:any[])=>"clip";const meterKeyFor=(..._args:any[])=>"reelmo";
    const assertMonthlyHeadroom=(..._args:any[])=>{};const orgMonthSpendCents=async(..._args:any[])=>0;
    const adminClient=()=>({from(_table:string){const q:any={select(_s:string){return q;},eq(_k:string,_v:any){return q;},maybeSingle:async()=>({data:{role:"owner"},error:null})};return q;}});
    async function durableRateLimit(key:string,_max:number,_seconds:number){calls.push(key);if(key.includes("idem")){if(seen.has(key))return false;seen.add(key);}return true;}
    async function chargeRateReceipt(key:string,max:number,windowSeconds:number){return {accepted:await durableRateLimit(key,max,windowSeconds),receipt:{key,windowSeconds,windowStart:"2026-10-05T00:00:00.000Z"}};}
    const refundRateReceipt=async(_receipt:unknown)=>true;
    ${body}
  `;
  const module = await import(
    `data:application/typescript;base64,${
      btoa(String.fromCharCode(...new TextEncoder().encode(fixture)))
    }`
  );
  const user = body.includes("userId: string")
    ? "synthetic-user"
    : { id: "synthetic-user", is_anonymous: false };
  const operationSeen=new Set<string>();
  return {
    calls: module.calls as string[],
    run: async (key?: string) => {
      const req = new Request("https://fixture.invalid/paid", {
        method: "POST",
        headers: key === undefined ? {} : { "idempotency-key": key },
      });
      if(endpoint==="ai-photo"||endpoint==="ai-chapters"){
        // These handlers now admit the permanent operation before quota. The
        // removed 120s counter must not block saved-result recovery.
        requiredIdempotencyKey(req);
        await fundingContext("synthetic-user","synthetic-org",req,{},async(rpc,args)=>{
          assertEquals(rpc,"serving_operation_begin");
          const operation="idem-operation:"+args.p_key;
          module.calls.push(operation);
          if(operationSeen.has(operation))return {data:null,error:{message:"RP409: This operation already started"}};
          operationSeen.add(operation);return {data:{begun:true},error:null};
        });
      }
      return module[name](
        user,
        req,
        endpoint === "ai-chapters" ? "synthetic-org" : "reel",
      );
    },
  };
}

async function assertRejectedBeforeMeter(
  fixture: Awaited<ReturnType<typeof loadGuard>>,
  key?: string,
) {
  await assertRejects(() => fixture.run(key), HttpError);
  assertEquals(fixture.calls.length, 0, "Invalid request charged a meter");
}

for (const [endpoint, name] of routes) {
  Deno.test(`${endpoint} actual paid guard rejects missing/long/space keys before meters and blocks a valid replay`, async () => {
    const fixture = await loadGuard(endpoint, name);
    for (const key of [undefined, "x".repeat(129), "invalid key", "short"]) {
      await assertRejectedBeforeMeter(fixture, key);
    }
    const result = await fixture.run("one-logical-paid-tap");
    if (endpoint === "ai-video") {
      assertEquals(result.monthlyReceipt,{key:"reelmo:synthetic-org",windowSeconds:2592000,windowStart:"2026-10-05T00:00:00.000Z"});
      assertEquals(result.burstReceipt,{key:"aivideo:synthetic-org",windowSeconds:300,windowStart:"2026-10-05T00:00:00.000Z"});
    }
    assert(fixture.calls.some((key) => key.includes("idem")));
    const allowanceCalls = fixture.calls.filter(key=>!key.includes("idem"));
    try {
      await fixture.run("one-logical-paid-tap");
      throw Error("Replay admitted");
    } catch (error) {
      assert(error instanceof HttpError && error.status === 409);
    }
    assertEquals(fixture.calls.filter(key=>!key.includes("idem")),allowanceCalls,"A duplicate request must not charge new allowance windows");
  });
}

Deno.test("actual guard negative control detects a removed required-key check", async () => {
  const mutant = await loadGuard("ai-video", "guardGenerate", true);
  await assertRejects(() => assertRejectedBeforeMeter(mutant));
  assert(
    mutant.calls.length > 0,
    "Mutation did not reach an admission boundary",
  );
});
