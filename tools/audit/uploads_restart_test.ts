// Execute the actual uploads Deno handler. SQL/storage responses below are
// fixtures; the independent test_upload_restart_db.py executes the actual RPCs.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fixture, type Fixture, type Row } from "./upload_route_fixture.ts";

const intent = "f472986c-98ac-4c8e-b7fd-7726adf4a110";
const consent = {confirm_new_attempt: true};
const headers = {"idempotency-key": intent};
const restart = (f: Fixture, body: Row = consent, key = intent) =>
  f.request("restart", body, {"idempotency-key": key});
function responseState(f: Fixture, asset: Row, reason: string | null = null, generation = 1) {
  f.asset = asset;
  return Response.json({asset, restart_required: reason != null, restart_reason: reason, restart_generation: generation});
}

Deno.test("expired renewal is a typed no-capability receipt without spending", () => fixture(async (f) => {
  f.recoveryReason = "expired";
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals([ticket.restart_required, ticket.restart_reason, ticket.restart_generation], [true,"expired",0]);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.operations.size, 0);
  assertEquals(f.charges.length, 0);
  assertEquals(f.rpcCalls.map((c) => c.name), ["upload_restart_state"]);
}));

Deno.test("active dispatch returns wait receipt not restart permission or another capability", () => fixture(async (f) => {
  f.retryAfterSeconds = 450;
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.retry_after_seconds, 450);
  assertEquals(ticket.restart_required, false);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.operations.size, 0);
}));

Deno.test("restart refuses absent false or expanded consent before RPC", () => fixture(async (f) => {
  // If the real handler loses consent enforcement, a functioning synthetic
  // mutation returns200; a missing fixture RPC must not be the failure signal.
  f.rpcHandler = (name) => name === "restart_upload_asset"
    ? responseState(f, {...f.asset!,id:"fixture-unapproved-child"}) : undefined;
  for (const body of [{}, {confirm_new_attempt:false}, {...consent,bytes:1}, {...consent,role:"render"}]) {
    assertEquals((await restart(f, body)).status, 400);
  }
  assertEquals(f.rpcCalls, []);
  assertEquals(f.operations.size, 0);
}));

Deno.test("restart requires stable UUID key before reservation mutation", () => fixture(async (f) => {
  for (const key of ["", "a-new-random-string", "00000000-0000-0000-0000-000000000000"]) {
    assertEquals((await restart(f, consent, key)).status, 400);
  }
  assertEquals(f.rpcCalls, []);
}));

Deno.test("actual restart route sends only actor old asset and intent then tickets the child", () => fixture(async (f) => {
  const child = {...f.asset!, id:"fixture-child",storage_key:"uploads/fixture-org/fixture-listing/fixture-child.mov"};
  f.rpcHandler = (name, args) => {
    if (name !== "restart_upload_asset") return undefined;
    assertEquals(args, {p_asset:"fixture-asset",p_actor:"fixture-user",p_restart:intent});
    return responseState(f, child);
  };
  const response = await restart(f);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.asset_id, "fixture-child");
  assertEquals(ticket.restart_generation, 1);
  assertEquals(ticket.restart_required, false);
  assert(new URL(ticket.put_url).pathname.startsWith("/v2/"));
  assertEquals([...f.operations.values()].map((op) => op.asset_id), ["fixture-child"]);
  assertEquals(f.rpcCalls.filter((c) => c.name === "reserve_upload_assets"), []);
  assertEquals(f.deletes, []);
}));

Deno.test("completion winning between HTTP read and restart RPC returns original complete receipt", () => fixture(async (f) => {
  f.rpcHandler = (name) => name === "restart_upload_asset"
    ? responseState(f, {...f.asset!,uploaded:true}, null, 0) : undefined;
  const response = await restart(f);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals([ticket.asset_id,ticket.uploaded], ["fixture-asset",true]);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.operations.size, 0);
}));

Deno.test("lost-response replay returns expired direct child without allocating a grandchild", () => fixture(async (f) => {
  f.rpcHandler = (name) => name === "restart_upload_asset"
    ? responseState(f, {...f.asset!,id:"fixture-child"}, "expired", 1) : undefined;
  const response = await restart(f);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals([ticket.asset_id,ticket.restart_required,ticket.restart_generation], ["fixture-child",true,1]);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.operations.size, 0);
}));

Deno.test("lost-response replay returns completed direct child without transfer", () => fixture(async (f) => {
  f.rpcHandler = (name) => name === "restart_upload_asset"
    ? responseState(f, {...f.asset!,id:"fixture-child",uploaded:true}, null, 2) : undefined;
  const response = await restart(f);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals([ticket.asset_id,ticket.uploaded,ticket.restart_generation], ["fixture-child",true,2]);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.operations.size, 0);
}));

Deno.test("lost-response multipart child returns only its confirmed original receipts", () => fixture(async (f) => {
  f.multipart(); f.asset!.id = "fixture-child"; f.operations.clear(); f.confirmed();
  f.rpcHandler = (name) => name === "restart_upload_asset" ? responseState(f, {...f.asset!}) : undefined;
  const response = await restart(f);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.asset_id, "fixture-child");
  assertEquals(ticket.confirmed_parts, [{number:1,etag:'"AAAA"'}]);
  assertEquals(f.physicalParts.size, 0);
}));

Deno.test("durable restart outage stays an error and never calls reserve or abort fallback", () => fixture(async (f) => {
  f.rpcFailures.add("restart_upload_asset");
  const before = structuredClone(f.asset);
  const response = await restart(f);
  assertEquals(response.status, 503);
  assertEquals((await response.json()).restart_required, undefined);
  assertEquals(f.asset, before);
  assertEquals(f.rpcCalls.map((c) => c.name), ["restart_upload_asset"]);
  assertEquals(f.deletes, []);
}));

Deno.test("exhausted four-attempt chain returns exact reason and no new transfer", () => fixture(async (f) => {
  f.rpcHandler = (name) => name === "restart_upload_asset"
    ? Response.json({message:"RP409: upload_restart_exhausted"}, {status:400}) : undefined;
  const response = await restart(f);
  assertEquals(response.status, 409);
  assertEquals((await response.json()).error, "upload_restart_exhausted");
  assertEquals(f.operations.size, 0);
}));

Deno.test("marketing cannot restart or acquire recovery capabilities", () => fixture(async (f) => {
  f.writeRole = "marketing";
  assertEquals((await restart(f)).status, 403);
  assertEquals((await f.request("renew")).status, 403);
  assertEquals(f.rpcCalls, []);
}));

Deno.test("asset outside visible tenant cannot reach restart mutation", () => fixture(async (f) => {
  f.asset = null;
  assertEquals((await restart(f)).status, 404);
  assertEquals(f.rpcCalls, []);
}));

Deno.test("invalid recovery receipt fails closed without planning a transfer", () => fixture(async (f) => {
  for (const fields of [{restart_generation:4}, {restart_reason:"arbitrary",restart_required:true},
    {retry_after_seconds:0}, {retry_after_seconds:901}, {restart_required:"yes"}]) {
    f.rpcHandler = (name) => name === "restart_upload_asset" ? Response.json({asset:f.asset,
      restart_required:false,restart_reason:null,restart_generation:1,...fields}) : undefined;
    assertEquals((await restart(f)).status, 503);
  }
  assertEquals(f.operations.size, 0);
}));

Deno.test("misconfigured gateway cannot retire an old ticket in restart RPC", () => fixture(async (f) => {
  Deno.env.set("UPLOAD_GATEWAY_ALLOWED_ORIGIN", "https://different.invalid");
  assertEquals((await f.request("restart",consent,headers)).status, 503);
  assertEquals(f.rpcCalls, []);
  assertEquals(f.asset!.upload_aborted, false);
}));
