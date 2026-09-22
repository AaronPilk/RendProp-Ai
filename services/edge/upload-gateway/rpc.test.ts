import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { stateClient } from "./rpc.ts";
import { TransportError } from "../../supabase/functions/uploads/gateway_contract.ts";

const ORIGIN = "https://state-fixture.invalid",
  SECRET = "synthetic-state-service-key-not-real";
Deno.test("state RPC uses only explicit allowlisted destination and fixed operation", async () => {
  const before = globalThis.fetch;
  let calls = 0;
  try {
    globalThis.fetch = async (input, init) => {
      const req = new Request(input, init);
      calls++;
      assertEquals(req.url, ORIGIN + "/rest/v1/rpc/claim_upload_operation");
      assertEquals(req.method, "POST");
      assertEquals(req.redirect, "manual");
      assertEquals(req.headers.get("authorization"), `Bearer ${SECRET}`);
      assertEquals(await req.json(), { p_operation: "synthetic" });
      return Response.json({ dispatch: false });
    };
    assertEquals(
      await stateClient(ORIGIN, ORIGIN, SECRET)("claim_upload_operation", {
        p_operation: "synthetic",
      }),
      { dispatch: false },
    );
    assertEquals(calls, 1);
  } finally {
    globalThis.fetch = before;
  }
});
for (const value of ["null", "not-json", "x".repeat(32769)]) {
  Deno.test(`invalid state response fails closed (${value.length} bytes)`, async () => {
    const before = globalThis.fetch;
    try {
      globalThis.fetch = () => Promise.resolve(new Response(value));
      await assertRejects(
        () => stateClient(ORIGIN, ORIGIN, SECRET)("claim_upload_operation", {}),
        TransportError,
      );
    } finally {
      globalThis.fetch = before;
    }
  });
}
Deno.test("unavailable state RPC remains 503 and is not automatically retried", async () => {
  const before = globalThis.fetch;
  let calls = 0;
  try {
    globalThis.fetch = () => {
      calls++;
      return Promise.resolve(
        Response.json({ message: "unavailable" }, { status: 503 }),
      );
    };
    const error = await assertRejects(
      () => stateClient(ORIGIN, ORIGIN, SECRET)("claim_upload_operation", {}),
      TransportError,
    );
    assertEquals(error.status, 503);
    assertEquals(calls, 1);
  } finally {
    globalThis.fetch = before;
  }
});
