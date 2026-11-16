import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deliverySummaries, resendClientLead } from "./client-delivery.ts";
const USER = "c0100101-0000-4000-8000-000000000001",
  ORG = "c0100101-0000-4000-8000-000000000002",
  LEAD = "c0100101-0000-4000-8000-000000000003",
  REQUEST = "c0100101-0000-4000-8000-000000000004";
Deno.test("resend uses saved recipient RPC rather than arbitrary forwarding", async () => {
  let call: any;
  const reply = {
    ok: true,
    delivery: { state: "queued", recipient_email: "client@fixture.invalid" },
  };
  const result = await resendClientLead(
    {
      rpc: async (name: string, args: unknown) => {
        call = { name, args };
        return { data: reply, error: null };
      },
    },
    USER,
    ORG,
    LEAD,
    { request_id: REQUEST, expected_recipient_email: "client@fixture.invalid" },
  );
  assertEquals(result, reply);
  assertEquals(call, {
    name: "client_lead_resend",
    args: {
      p_user: USER,
      p_org: ORG,
      p_lead: LEAD,
      p_request: REQUEST,
      p_expected_email: "client@fixture.invalid",
    },
  });
});
Deno.test("send request needs durable request ID and explicit recipient confirmation", async () => {
  for (
    const body of [{ request_id: REQUEST }, {
      request_id: "bad",
      expected_recipient_email: "client@fixture.invalid",
    }, {
      request_id: REQUEST,
      expected_recipient_email: "client@fixture.invalid",
      to: "other@fixture.invalid",
    }]
  ) await assertRejects(() => resendClientLead({}, USER, ORG, LEAD, body));
});
Deno.test("delivery statuses bind current workspace and never return raw database failure", async () => {
  let call: any;
  const result = await deliverySummaries(
    {
      rpc: async (name: string, args: unknown) => {
        call = { name, args };
        return { data: { [LEAD]: null }, error: null };
      },
    },
    USER,
    ORG,
    [LEAD],
  );
  assertEquals(result, { [LEAD]: null });
  assertEquals(call.args, { p_user: USER, p_org: ORG, p_leads: [LEAD] });
  const error = await assertRejects(() =>
    deliverySummaries(
      {
        rpc: () =>
          Promise.resolve({ data: null, error: { message: "secret token" } }),
      },
      USER,
      ORG,
      [LEAD],
    )
  );
  assert(!(error as Error).message.includes("secret"));
  assertEquals((error as any).status, 503);
});
