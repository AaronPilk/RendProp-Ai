import { EmailMessage } from "./email.ts";
import { OutboxRow } from "./deliver.ts";
// deno-lint-ignore no-explicit-any
export async function prepareClientMessage(
  admin: any,
  row: OutboxRow,
): Promise<EmailMessage | null> {
  const verification = row.category === "client_recipient_verification";
  const id = verification ? row.client_verification_id : row.client_delivery_id;
  if (!["client_lead_received", "client_recipient_verification"].includes(row.category) || !id) return null;
  const { data, error } = await admin.rpc(verification ? "client_recipient_verification_prepare" : "client_lead_prepare", {
    ...(verification ? { p_verification: id } : { p_delivery: id }),
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
    data.idempotency_key !== `${verification ? "client-verification" : "client-lead"}/${id}`
  ) throw new Error("Client delivery payload could not be verified.");
  return {
    to: data.to,
    from: data.from,
    subject: data.subject,
    text: data.text,
    idempotencyKey: data.idempotency_key,
  };
}
