import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { photoPackageContext } from "./photo-package-context.ts";
const now=Date.parse("2026-10-07T00:00:00Z"), org="synthetic-org", actor="synthetic-actor";
function value() { return {org_id:org, policy:"one-gemini-1k-4096-plus-one-kontext-20261007",tariff_version:"published-standard-20261006",starts_at:"2026-10-01T00:00:00Z",ends_at:"2026-11-01T00:00:00Z",photo_admissions:{cap:5,used:2,remaining:3},photo_hold_cents:35.1296,protected_photo_cents:176,other_ai:{cap_cents:38,used_cents:3,remaining_cents:35}}; }
const client=(data:unknown,error:unknown=null)=>({rpc:(name:string,args:unknown)=>{assertEquals(name,"serving_photo_package_context");assertEquals(args,{p_actor:actor,p_org:org});return {data,error};}});
Deno.test("package metadata preserves legacy absence and strips non-public receipt fields",async()=>{
  assertEquals(await photoPackageContext(client(null),actor,org,now),null);
  assertEquals(await photoPackageContext(client({...value(),funding_id:"private",actor_id:"private"}),actor,org,now),value());
});
Deno.test("package metadata refuses wrong org, expired interval, unknown tariff, malformed counts and unverifiable upstream",async()=>{
  for (const patch of [{org_id:"foreign"},{ends_at:"2026-10-06T00:00:00Z"},{starts_at:"invalid"},{policy:"unpriced"},{tariff_version:"unpriced"},{photo_hold_cents:0},{protected_photo_cents:175},{photo_admissions:{cap:5,used:2,remaining:4}},{photo_admissions:{cap:5.5,used:2,remaining:3.5}},{other_ai:{cap_cents:38,used_cents:3,remaining_cents:38}},{other_ai:{cap_cents:38,used_cents:-1,remaining_cents:39}}]) {
    await assertRejects(()=>photoPackageContext(client({...value(),...patch}),actor,org,now));
  }
  await assertRejects(()=>photoPackageContext(client(value(),{code:"unavailable"}),actor,org,now));
});
