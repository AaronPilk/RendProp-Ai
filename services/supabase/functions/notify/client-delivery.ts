import { EmailMessage } from "./email.ts";
import { OutboxRow } from "./deliver.ts";
// deno-lint-ignore no-explicit-any
export async function prepareClientMessage(
  admin: any,
  row: OutboxRow,
): Promise<EmailMessage | null> {
  if (row.category !== "client_lead_received" || !row.client_delivery_id) {
    return null;
  }
  const { data, error } = await admin.rpc("client_lead_prepare", {
    p_delivery: row.client_delivery_id,
    p_outbox: row.id,
    p_from: Deno.env.get("NOTIFY_FROM_EMAIL") ?? "",
  });
  if (error) {
    throw new Error("Client delivery authority could not be verified.");
  }
  if (data === null) return null;
  if (
    !data || typeof data.to !== "string" || data.to !== row.to_email ||
    typeof data.from !== "string" || typeof data.subject !== "string" ||
    typeof data.text !== "string" ||
    data.idempotency_key !== `client-lead/${row.client_delivery_id}`
  ) throw new Error("Client delivery payload could not be verified.");
  return {
    to: data.to,
    from: data.from,
    subject: data.subject,
    text: data.text,
    idempotencyKey: data.idempotency_key,
  };
}
