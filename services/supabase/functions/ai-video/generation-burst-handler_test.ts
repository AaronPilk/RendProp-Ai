// Execute the actual generation guard. An eight-photo reel's bounded retry
// batch fits even without QC burst refunds; paid/monthly/tenant gates remain.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const start = source.indexOf("async function guardGenerate("), end = source.indexOf("\n}\n", start);
assert(start > 0 && end > start);
const actualGuard = source.slice(start, end + 3);
const constants = ["GEN_MAX_PER_WINDOW", "REEL_MAX_PER_WINDOW", "GEN_WINDOW_SECONDS", "MONTH_SECONDS"].map((name) => {
  const match = source.match(new RegExp(`const ${name}[^;]*;`)); assert(match); return match[0];
}).join("\n");
const dataModule = (text: string) => "data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(text)));
async function fixture(oldCap = false) {
  const guard = oldCap ? actualGuard.replace('kind === "reel" ? REEL_MAX_PER_WINDOW : GEN_MAX_PER_WINDOW', "GEN_MAX_PER_WINDOW") : actualGuard;
  if (oldCap) assert(guard !== actualGuard, "old 12-attempt cap mutation anchor missing");
  const module = await import(dataModule(`
    import {HttpError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {requiredIdempotencyKey} from ${JSON.stringify(new URL("../_shared/idempotency.ts", import.meta.url).href)};
    import {assertMonthlyHeadroom} from ${JSON.stringify(new URL("./dronecost.ts", import.meta.url).href)};
    type PaidAiCaller=any;type GenKind=any;type GenerateCharge=any;
    ${constants}
    export function make(state:any){
      const preferredOrg=(req:Request)=>req.headers.get("X-Org-Id")??undefined;
      const contentOrgForUser=async(actor:string,org:string,listing:string,write:boolean)=>{state.permissions++;if(actor!=="actor"||org!=="own-org"||listing!=="own-listing"||write!==true||state.denied)throw new HttpError(403,"listing denied");return org;};
      const adminClient=()=>({}),assertPaidAiIdentity=async()=>{if(state.guest)throw new HttpError(403,"account required");};
      const entitlementForCharge=async()=>({plan:"team",cogs_ceiling_cents:state.ceiling});
      const capFor=()=>state.monthlyCap,labelFor=(kind:string)=>kind,meterKeyFor=(kind:string)=>kind+"mo";
      const quotaError=()=>new HttpError(402,"plan allowance"),orgMonthSpendCents=async()=>state.spent;
      const durableRateLimit=async(key:string)=>{if(state.keys.has(key))return false;state.keys.add(key);return true;};
      const libraryBillingOrg=async()=>"own-org";
      const chargeRateReceipt=async(key:string,cap:number,seconds:number)=>{state.calls.push({key,cap,seconds});const count=state.counts.get(key)??0;const accepted=count<cap;if(accepted)state.counts.set(key,count+1);return {accepted,receipt:{key,windowStart:"2026-10-12T00:00:00Z"}};};
      const refundRateReceipt=async(receipt:any)=>{state.counts.set(receipt.key,(state.counts.get(receipt.key)??0)-1);};
      ${guard}
      return async(kind:string,key:string)=>guardGenerate({id:"actor"},new Request("https://fixture.invalid/ai-video/reel-clip",{headers:{"X-Org-Id":"own-org","Idempotency-Key":"burst-fixture-"+key}}),kind,25,"own-org","own-listing");
    }
  `));
  const state = { counts: new Map<string,number>(), keys: new Set<string>(), calls: [] as any[], permissions: 0,
    denied: false, guest: false, ceiling: 10000, spent: 0, monthlyCap: 100 };
  return { state, run: module.make(state) };
}
Deno.test("actual reel guard admits an eight-photo twice-attempted batch without refunds", async () => {
  const f = await fixture();
  for (let i = 0; i < 16; i++) assertEquals((await f.run("reel", "eight-photo-" + i)).orgId, "own-org");
  assertEquals(f.state.counts.get("aivideo:own-org"), 16);
  assertEquals(f.state.counts.get("reelmo:own-org"), 16);
  assertEquals(f.state.permissions, 16);
  assert(f.state.calls.every(c => c.key.endsWith(":own-org")));
  assert(f.state.calls.filter(c => c.key === "aivideo:own-org").every(c => c.cap === 20 && c.seconds === 300));
});
Deno.test("actual reel burst rejects attempt 21 without consuming monthly allowance", async () => {
  const f = await fixture();
  for (let i = 0; i < 20; i++) await f.run("reel", "twenty-" + i);
  await assertRejects(() => f.run("reel", "twenty-one"), Error, "generation limit");
  assertEquals(f.state.counts.get("reelmo:own-org"), 20);
});
Deno.test("actual aerial and drone bursts remain twelve with the same billing scope", async () => {
  for (const kind of ["aerial", "drone"]) {
    const f = await fixture();
    for (let i = 0; i < 12; i++) await f.run(kind, kind + i);
    await assertRejects(() => f.run(kind, kind + "13"), Error, "generation limit");
    assertEquals(f.state.counts.get(kind + "mo:own-org"), 12);
    assertEquals(f.state.calls.at(-1)?.cap, 12);
  }
});
Deno.test("actual reel guard retains monthly and financial refusals", async () => {
  const f = await fixture(); f.state.monthlyCap = 1;
  await f.run("reel", "one");
  await assertRejects(() => f.run("reel", "two"), Error, "plan allowance");
  assertEquals(f.state.counts.get("aivideo:own-org"), 1);
  const money = await fixture(); money.state.ceiling = 20;
  await assertRejects(() => money.run("reel", "money"), Error);
  assertEquals(money.state.calls.length, 0);
});
Deno.test("actual reel guard retains fresh tenant and paid identity refusals", async () => {
  for (const field of ["denied", "guest"] as const) {
    const f = await fixture(); f.state[field] = true;
    await assertRejects(() => f.run("reel", field), Error);
    assertEquals(f.state.calls.length, 0);
  }
});
Deno.test("negative control: the original twelve-attempt cap rejects a legitimate sixteen-attempt batch", async () => {
  const f = await fixture(true);
  for (let i = 0; i < 12; i++) await f.run("reel", "old-cap-" + i);
  await assertRejects(() => f.run("reel", "old-cap-13"), Error, "generation limit");
  assertEquals(f.state.counts.get("reelmo:own-org"), 12);
});
