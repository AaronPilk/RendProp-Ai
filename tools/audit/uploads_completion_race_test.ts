// Actual handler, synthetic SQL/R2 only. The v2 journal strengthens the prior
// race gate: no second physical copy is authorized at all.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fixture, latch, object, TICKET } from "./upload_route_fixture.ts";

Deno.test("a delayed second complete must not replace an already-completed object", () =>
  fixture(async (f) => {
    const entered = latch(), release = latch();
    f.beforeCopy = async () => {
      entered.resolve();
      await release.promise;
    };
    const first = f.request("complete");
    await entered.promise;
    const competing = await f.request("complete");
    assertEquals(competing.status, 503);
    assertEquals(
      f.copies.length,
      1,
      "One durable claim authorizes only one physical copy",
    );
    release.resolve();
    const response = await first;
    assertEquals(response.status, 200);
    const winner = await response.json();
    f.objects.set(`_staging/${TICKET}`, object("BBBB"));
    const replay = await f.ok();
    assertEquals(replay.storage_key, winner.storage_key);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
    assertEquals(f.copies.length, 1);
    assertEquals(f.asset!.uploaded, true);
  }));
