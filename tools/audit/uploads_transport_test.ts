import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fixture, object, TICKET } from "./upload_route_fixture.ts";

Deno.test("missing durable reservation never falls back to a memory counter or presigned PUT", () =>
  fixture(async (f) => {
    f.asset = null;
    f.rpcFailures.add("reserve_upload_assets");
    const response = await f.request("ticket", {
      listing_id: "fixture-listing",
      filename: "a.mov",
      bytes: 4,
    });
    assertEquals(response.status, 503);
    assertEquals(f.asset, null);
    assertEquals(f.charges, []);
    assertEquals(f.copies, []);
  }));
Deno.test("misconfigured gateway allowlist cannot consume a reservation", () =>
  fixture(async (f) => {
    Deno.env.set("UPLOAD_GATEWAY_ALLOWED_ORIGIN", "https://different.invalid");
    assertEquals(
      (await f.request("ticket", { listing_id: "fixture-listing", bytes: 4 }))
        .status,
      503,
    );
    assertEquals(f.charges, []);
  }));
Deno.test("invalid later batch item causes no reservation or partial asset insert", () =>
  fixture(async (f) => {
    f.asset = null;
    assertEquals(
      (await f.request("batch", {
        listing_id: "fixture-listing",
        files: [{ filename: "a.jpg", bytes: 4 }, {
          filename: "b.jpg",
          bytes: 0,
        }],
      })).status,
      400,
    );
    assertEquals(f.charges, []);
    assertEquals(f.asset, null);
  }));
Deno.test("lost copy receipt recovers its existing immutable candidate without a second copy", () =>
  fixture(async (f) => {
    f.rpcFailures.add("finish_upload_operation");
    assertEquals((await f.request("complete")).status, 503);
    assertEquals(f.copies.length, 1);
    assertEquals(f.asset!.uploaded, false);
    f.rpcFailures.delete("finish_upload_operation");
    const winner = await f.ok();
    assertEquals(f.copies.length, 1);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
  }));
Deno.test("unknown copy receipt without a provable object remains charged and cannot redispatch", () =>
  fixture(async (f) => {
    f.failCopy = true;
    assertEquals((await f.request("complete")).status, 502);
    f.failCopy = false;
    assertEquals((await f.request("complete")).status, 503);
    assertEquals(f.copies.length, 1);
    assertEquals(f.asset!.uploaded, false);
    assertEquals(
      [...f.operations.values()].find((op) => op.kind === "copy")?.state,
      "uncertain",
    );
  }));
Deno.test("multipart initialization lost response recovers exactly the recorded session", () =>
  fixture(async (f) => {
    f.asset = null;
    f.objects.clear();
    f.failInitializationReply = true;
    const body = {
      listing_id: "fixture-listing",
      filename: "room.mov",
      kind: "video",
      bytes: 67108865,
      content_type: "video/quicktime",
    };
    assertEquals((await f.request("ticket", body)).status, 502);
    assertEquals(f.sessions.size, 1);
    f.failInitializationReply = false;
    const response = await f.request("ticket", body);
    assertEquals(response.status, 200);
    const ticket = await response.json();
    assertEquals(ticket.upload_id, "fixture-new-upload");
    assertEquals(ticket.part_size, 33554432);
    assertEquals(ticket.part_count, 3);
    assertEquals(f.sessions.size, 1);
    assertEquals(f.charges.length, 1);
  }));
Deno.test("lost multipart part receipt recovers ListParts exact number and bytes", () =>
  fixture(async (f) => {
    f.multipart();
    const op = f.operation("part", 1);
    Object.assign(op, { state: "uncertain", claim: "fixture-dispatched" });
    f.physicalParts.set(1, { bytes: 4, etag: '"AAAA"' });
    const response = await f.request("part-urls", { numbers: [1] });
    assertEquals(response.status, 200);
    const { urls } = await response.json();
    assertEquals(urls.length, 1);
    assert(new URL(urls[0].url).pathname.startsWith("/v2/"));
    assertEquals(op.state, "stored");
    assertEquals(op.etag, '"AAAA"');
  }));
Deno.test("wrong-size recovered part is never adopted or re-uploaded", () =>
  fixture(async (f) => {
    f.multipart();
    const op = f.operation("part", 1);
    Object.assign(op, { state: "uncertain", claim: "fixture-dispatched" });
    f.physicalParts.set(1, { bytes: 5, etag: '"AAAA"' });
    assertEquals((await f.request("part-urls", { numbers: [1] })).status, 503);
    assertEquals(op.state, "uncertain");
    assertEquals(f.asset!.uploaded, false);
  }));
Deno.test("user bearer cannot invoke service-only cleanup", () =>
  fixture(async (f) => {
    const response = await f.request("sweep");
    assertEquals(response.status, 403);
    assertEquals(f.asset!.uploaded, false);
    assertEquals(f.deletes, []);
  }));
Deno.test("completed winner is excluded from journaled sweep", () =>
  fixture(async (f) => {
    const winner = await f.ok();
    f.objects.set(`_staging/${TICKET}`, object("BBBB"));
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
    assertEquals(f.deletes.includes(String(winner.storage_key)), false);
  }));
