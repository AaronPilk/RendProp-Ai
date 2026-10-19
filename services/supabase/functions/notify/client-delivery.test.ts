import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { prepareClientMessage } from "./client-delivery.ts";
import { deliverEmail, type OutboxRow } from "./deliver.ts";
const id = "c0100101-0000-4000-8000-000000000004";
const row: OutboxRow = {
  id: "outbox-fixture",
  org_id: "org-fixture",
  user_id: null,
  to_email: "client@fixture.invalid",
  category: "client_lead_received",
  channel: "email",
  dedupe_key: `client-lead:${id}`,
  payload: {},
  attempts: 1,
  client_delivery_id: id,
};
const message = {
  to: row.to_email,
  from: "Studio <notify@fixture.invalid>",
  subject: "New inquiry",
  text: "Buyer: buyer@fixture.invalid\nPhone: 555-555-0101",
  idempotency_key: `client-lead/${id}`,
};
Deno.test("client provider send carries exact frozen content and stable idempotency key", async () => {
  const prev = [
    Deno.env.get("RESEND_API_KEY"),
    Deno.env.get("NOTIFY_FROM_EMAIL"),
  ];
  try {
    Deno.env.set("RESEND_API_KEY", "synthetic");
    Deno.env.set("NOTIFY_FROM_EMAIL", "Changed <else@fixture.invalid>");
    const calls: Request[] = [];
    const prepared = await prepareClientMessage({
      rpc: () => Promise.resolve({ data: message, error: null }),
    }, row);
    assert(prepared);
    for (let n = 0; n < 2; n++) {
      const outcome = await deliverEmail(
        row,
        row.to_email!,
        "https://public.fixture.invalid",
        (input, init) => {
          calls.push(new Request(input, init));
          return Promise.resolve(Response.json({ id: "provider-fixture" }));
        },
        prepared,
      );
      assertEquals(outcome.state, "sent");
    }
    assertEquals(calls[0].headers.get("Idempotency-Key"), `client-lead/${id}`);
    assertEquals(await calls[0].json(), await calls[1].json());
    assert(!prepared.text.includes("Settings"));
    assert(!prepared.text.includes("Rendprop"));
    assertEquals(prepared.from, message.from);
  } finally {
    for (
      const [n, v] of [["RESEND_API_KEY", prev[0]], [
        "NOTIFY_FROM_EMAIL",
        prev[1],
      ]] as const
    ) {
      if (v === undefined) Deno.env.delete(n);
      else Deno.env.set(n, v);
    }
  }
});
Deno.test("revoked routing returns null before provider capability", async () => {
  assertEquals(
    await prepareClientMessage({
      rpc: () => Promise.resolve({ data: null, error: null }),
    }, row),
    null,
  );
});
Deno.test("wrong recipient/key and unverifiable authority fail closed", async () => {
  for (
    const data of [{ ...message, to: "other@fixture.invalid" }, {
      ...message,
      idempotency_key: "wrong",
    }]
  ) {
    await assertRejects(() =>
      prepareClientMessage({
        rpc: () => Promise.resolve({ data, error: null }),
      }, row)
    );
  }
  await assertRejects(() =>
    prepareClientMessage({
      rpc: () =>
        Promise.resolve({
          data: null,
          error: { message: "synthetic offline" },
        }),
    }, row)
  );
});
