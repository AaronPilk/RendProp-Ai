import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// Execute the actual route body; only authenticated DB/workspace boundaries are synthetic.
async function fixture() {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  const start = source.indexOf(
    '    if (seg.length === 2 && seg[1] === "measurements") {',
  );
  const end = source.indexOf(
    '\n    if (seg.length === 2 && seg[1] === "client-contact")',
    start,
  );
  assert(start > 0 && end > start);
  const http = JSON.stringify(
    new URL("../_shared/http.ts", import.meta.url).href,
  );
  const body =
    `import {HttpError,assert,json,readJsonLimited,respondError}from ${http};
    export const state:any={calls:[],org:'22222222-2222-4222-8222-222222222222',actor:'11111111-1111-4111-8111-111111111111',deleting:false,error:null};
    const assertNotDeleting=async(user:string)=>{if(state.deleting)throw new HttpError(409,'Deleting');};
    const adminClient=()=>({rpc:async(name:string,args:any)=>{state.calls.push({name,args});return{data:{id:args.p_listing,org_id:args.p_org,details:{floor_measurements_v1:args.p_value},sqft:2000,status:'archived',sold_at:'2026-10-01'},error:state.error};}});
    export const handler=async(req:Request)=>{try{
      const seg=new URL(req.url).pathname.slice(1).split('/');const id=seg[0];
      const explicitOrg=req.headers.get('X-Org-Id')??undefined,user={id:state.actor};
      ${source.slice(start, end)}
      throw new HttpError(404,'Unknown route');
    }catch(error){return respondError(error);}};`;
  return await import(
    `data:application/typescript;base64,${
      btoa(String.fromCharCode(...new TextEncoder().encode(body)))
    }`
  );
}
const org = "22222222-2222-4222-8222-222222222222",
  lid = "33333333-3333-4333-8333-333333333333";
const value = JSON.stringify({
  version: 1,
  unit: "meters",
  rooms: [],
  updatedAt: 1000,
});
const request = (
  body: unknown = { expected: null, value },
  headers: Record<string, string> = { "X-Org-Id": org },
  id = lid,
  method = "PUT",
) =>
  new Request(`https://fixture.invalid/${id}/measurements`, {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
Deno.test("actual measurement route binds verified actor/workspace/listing and writes only CAS values", async () => {
  const f = await fixture();
  f.state.calls = [];
  f.state.deleting = false;
  f.state.error = null;
  const result = await f.handler(request());
  assertEquals(result.status, 200);
  assertEquals(f.state.calls, [{
    name: "save_listing_measurements",
    args: {
      p_actor: f.state.actor,
      p_org: org,
      p_listing: lid,
      p_expected: null,
      p_value: value,
    },
  }]);
  const receipt = await result.json();
  assertEquals(receipt.sqft, 2000);
  assertEquals(receipt.status, "archived");
  assertEquals(receipt.sold_at, "2026-10-01");
});
Deno.test("actual measurement route refuses listing facts and malformed or unscoped bodies before RPC", async () => {
  const f = await fixture();
  f.state.deleting = false;
  f.state.error = null;
  for (
    const [req, status] of [
      [request({ expected: null, value, sqft: 0 }), 400],
      [request({ value }), 400],
      [request({ expected: 3, value }), 400],
      [request({ expected: null, value: 3 }), 400],
      [request({ expected: null, value: "x".repeat(10001) }), 400],
      [request(undefined, {}), 409],
      [request(undefined, { "X-Org-Id": org }, "not-a-listing"), 400],
      [request(undefined, { "X-Org-Id": org }, lid, "PATCH"), 405],
    ] as const
  ) {
    f.state.calls = [];
    assertEquals((await f.handler(req)).status, status);
    assertEquals(f.state.calls.length, 0);
  }
});
Deno.test("actual measurement route surfaces stale CAS conflict and gates deleting accounts", async () => {
  const f = await fixture();
  f.state.deleting = false;
  for (const code of ["PT409", "40001"]) {
    f.state.calls = [];
    f.state.error = { code };
    const response = await f.handler(request());
    assertEquals(response.status, 409);
    assert((await response.json()).error.includes("local copy is safe"));
    assertEquals(f.state.calls.length, 1);
  }
  f.state.calls = [];
  f.state.deleting = true;
  assertEquals((await f.handler(request())).status, 409);
  assertEquals(f.state.calls.length, 0);
  f.state.deleting = false;
  for (
    const [code, status] of [["42501", 403], ["P0002", 404], ["22023", 400]]
  ) {
    f.state.error = { code, message: "PRIVATE RAW SQL must not escape" };
    const r = await f.handler(request());
    assertEquals(r.status, status);
    assert(!(await r.text()).includes("PRIVATE"));
  }
  f.state.error = null;
});
