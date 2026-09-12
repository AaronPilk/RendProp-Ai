import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fixture } from "./upload_route_fixture.ts";

Deno.test("renewal keeps exact asset and never creates another reservation", () => fixture(async (f) => {
  const before = f.asset!.id;
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.asset_id, before);
  assertEquals(ticket.transport_version, 2);
  assertEquals(ticket.uploaded, false);
  assert(new URL(ticket.put_url).pathname.startsWith("/v2/"));
  assertEquals(f.charges.length, 0);
  assertEquals(f.copies.length, 0);
}));

Deno.test("completion wins renewal with a completed receipt and no transfer capability", () => fixture(async (f) => {
  await f.ok();
  const before = f.asset!.id;
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.asset_id, before);
  assertEquals(ticket.uploaded, true);
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.charges.length, 0);
  assertEquals(f.copies.length, 1);
}));

Deno.test("renewal returns original confirmed multipart ETags without another part write", () => fixture(async (f) => {
  f.multipart();
  f.confirmed();
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.confirmed_parts, [{number: 1, etag: '"AAAA"'}]);
  assertEquals(ticket.upload_id, f.asset!.upload_id);
  assertEquals(f.charges.length, 0);
  assertEquals(f.physicalParts.size, 0);
}));

Deno.test("legacy renewal refuses upgrade or cancellation without user consent", () => fixture(async (f) => {
  f.asset!.transport_version = 1;
  const response = await f.request("renew");
  assertEquals(response.status, 409);
  assertEquals((await response.json()).error, "Legacy upload must be reticketed after rollout cleanup");
  assertEquals(f.asset!.transport_version, 1);
  assertEquals(f.asset!.upload_aborted, false);
  assertEquals(f.charges.length, 0);
  assertEquals(f.operations.size, 0);
}));

Deno.test("completed legacy tickets remain usable without re-ticketing", () => fixture(async (f) => {
  f.asset!.transport_version = 1;
  f.asset!.uploaded = true;
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  assertEquals((await response.json()).transport_version, 1);
  assertEquals(f.charges.length, 0);
}));

Deno.test("aborted v2 reservation cannot renew its capability", () => fixture(async (f) => {
  f.asset!.upload_aborted = true;
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.restart_required, true);
  assertEquals(ticket.restart_reason, "cancelled");
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.charges.length, 0);
  assertEquals(f.operations.size, 0);
}));

Deno.test("uncertain write cannot produce a renewed capability before storage is provable", () => fixture(async (f) => {
  const op = f.operation("single");
  op.state = "uncertain";
  op.claim = "previous-owner";
  f.objects.clear();
  const response = await f.request("renew");
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.restart_required, true);
  assertEquals(ticket.restart_reason, "interrupted");
  assertEquals(ticket.put_url, undefined);
  assertEquals(f.charges.length, 0);
  assertEquals(f.copies.length, 0);
  assertEquals(f.operations.size, 1);
  assertEquals(op.state, "uncertain");
}));
