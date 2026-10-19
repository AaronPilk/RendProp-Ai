import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { beginPropertyAttempt, finishPropertyAttempt } from "./provider-attempt-receipt.ts";
import { propertyRequestId } from "./property/provider.ts";
import { HttpError } from "./http.ts";

const actor = "b9100000-0000-4000-8000-000000000001", org = "b9100000-0000-4000-8000-000000000002", id = "b9100000-0000-4000-8000-000000000003";
const request = () => new Request("https://closed.invalid/property", { headers: { "idempotency-key": "PRIVATE-KEY-SENTINEL" } });
function authority(change: (row: Record<string, unknown>) => unknown = row => row) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  return { calls, async rpc(name: string, args: Record<string, unknown>) {
    calls.push({ name, args });
    if (name === "provider_attempt_finish") return { data: { saved: true, attempt_id: id }, error: null };
    return { data: change({ attempt_id: id, actor_id: actor, org_id: org, operation_sha256: args.p_operation_sha256, input_sha256: args.p_input_sha256, dispatch: true, outcome: "intent" }), error: null };
  } };
}
Deno.test("receipt helper binds exact actor/org/input identity and exports only hashed operation/input", async () => {
  const a = authority(), attempt = await beginPropertyAttempt(a, actor, org, request(), "PRIVATE-ADDRESS-SENTINEL");
  assertEquals(attempt, { actor, org, id }); assertEquals(a.calls.length, 1);
  const args = a.calls[0].args; assert(/^[a-f0-9]{64}$/.test(String(args.p_operation_sha256))); assert(/^[a-f0-9]{64}$/.test(String(args.p_input_sha256)));
  assert(!JSON.stringify(args).includes("PRIVATE"));
  assertEquals(await finishPropertyAttempt(a, attempt, { outcome: "hit", status: 200, requestId: "https://private.invalid/secret", estimatedCents: 7, ledgerStatus: "unconfirmed" }), true);
  assertEquals(a.calls[1].args.p_provider_request_id, null); assertEquals(a.calls[1].args.p_estimated_cents, 7);
});
Deno.test("lost or wrong-scope intent replies and duplicate/terminal replies never grant dispatch", async () => {
  for (const changed of [null, [], { actor_id: org }, { org_id: actor }, { attempt_id: "invalid" }, { operation_sha256: "changed" }, { input_sha256: "changed" }, { dispatch: false }, { outcome: "hit" }]) {
    const a = authority(row => changed === null || Array.isArray(changed) ? changed : { ...row, ...changed });
    await assertRejects(() => beginPropertyAttempt(a, actor, org, request(), "PRIVATE-ADDRESS-SENTINEL"), HttpError); assertEquals(a.calls.length, 1);
  }
  await assertRejects(() => beginPropertyAttempt({ rpc: async () => { throw new Error("PRIVATE-DB-SENTINEL"); } }, actor, org, request(), "private"), HttpError, "No property-records request was sent");
});
Deno.test("fresh incoming requests without a client operation retain distinct identities; no address-wide permanent tombstone", async () => {
  const a = authority(), req = () => new Request("https://closed.invalid/property");
  await beginPropertyAttempt(a, actor, org, req(), "same normalized address"); await beginPropertyAttempt(a, actor, org, req(), "same normalized address");
  assert(a.calls[0].args.p_operation_sha256 !== a.calls[1].args.p_operation_sha256); assertEquals(a.calls[0].args.p_input_sha256, a.calls[1].args.p_input_sha256);
});
Deno.test("lost terminal persistence remains unresolved and unsafe supplier IDs never enter accounting", async () => {
  const a = authority(), attempt = await beginPropertyAttempt(a, actor, org, request(), "private");
  assertEquals(await finishPropertyAttempt({ rpc: async () => ({ data: null, error: { message: "PRIVATE-FAILURE" } }) }, attempt, { outcome: "transport_unknown", status: null, requestId: null }), false);
  for (const value of ["person@example.com", "https://private.invalid/key", "eyJ.payload.signature", "inert-secret", ""])
    assertEquals(propertyRequestId(value), null);
  assertEquals(propertyRequestId(id.toUpperCase()), id);
});
