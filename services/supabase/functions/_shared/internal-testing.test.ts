import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";
import { masterTestingAccess, privateTestingContext, privateTestingMembers } from "./internal-testing.ts";

const user = "cb100510-0000-4000-8000-000000000001", org = "cb100510-0000-4000-8000-000000000002", host = "cb100510-0000-4000-8000-000000000003";
const context = { active: true, sponsor_org_id: host, sponsor_org_name: "Fixture tester team", private_org_id: org, beneficiary_user_id: user, plan: "team", source: "manual", unmetered_business_allowances: true };
function fixture(data: unknown, error: unknown = null) {
  const calls: unknown[] = [];
  const admin = { rpc: async (name: string, args: unknown) => { calls.push({ name, args }); return { data, error }; } } as unknown as SupabaseClient;
  return { admin, calls };
}
Deno.test("private testing context binds the verified caller and resource org only", async () => {
  const f = fixture(context); assertEquals(await privateTestingContext(f.admin, user, org), context);
  assertEquals(f.calls, [{name: "private_internal_testing_context", args: {p_user: user, p_private_org: org}}]);
  assertEquals(await privateTestingContext(fixture(null).admin, user, org), null);
});
for (const patch of [{private_org_id: host}, {beneficiary_user_id: host}, {sponsor_org_id: org}, {sponsor_org_id: "invalid"}, {active: false}, {source: "apple"}, {plan: "free"}, {unmetered_business_allowances: false}]) {
  Deno.test(`private testing rejects altered authority ${Object.keys(patch)[0]}`, async () => {
    const error = await assertRejects(() => privateTestingContext(fixture({...context, ...patch}).admin, user, org), HttpError); assertEquals(error.status, 503);
  });
}
Deno.test("testing lookup failures never become free access or shared access", async () => {
  for (const data of [undefined, [], {}, true]) {
    const error = await assertRejects(() => privateTestingContext(fixture(data).admin, user, org), HttpError); assertEquals(error.status, 503);
  }
  for (const call of [privateTestingContext(fixture(null,{message:"failed"}).admin,user,org),masterTestingAccess(fixture(null).admin,host),privateTestingMembers(fixture(null).admin,user,host)]) {
    const error = await assertRejects(() => call, HttpError); assertEquals(error.status, 503);
  }
});
Deno.test("private roster and master lookup pass only narrow service RPC arguments", async () => {
  const member = {user_id:user,role:"agent",name:null,email:null,private_testing:true,benefits_active:true,joined_at:"2026-10-05T00:00:00Z"} as const;
  const f = fixture([member]); assertEquals(await privateTestingMembers(f.admin,user,host),[member]);
  assertEquals(f.calls,[{name:"private_internal_testing_members",args:{p_actor:user,p_sponsor_org:host}}]);
  assertEquals(await masterTestingAccess(fixture(true).admin,host),true);
  assertEquals(await masterTestingAccess(fixture(false).admin,host),false);
  for (const data of [[member,member],[{...member,role:"owner"}],[{...member,private_testing:false}],[{...member,email:42}]]) {
    const error = await assertRejects(() => privateTestingMembers(fixture(data).admin,user,host),HttpError); assertEquals(error.status,503);
  }
});
