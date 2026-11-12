import { useEffect, useRef, useState } from "react";
import type { BusinessApi } from "./api";
import type { ClientDelivery, Lead } from "./model";

export const clientDeliveryLabels: Record<ClientDelivery["state"], string> = { queued: "Email queued", sending: "Email sending", email_sent: "Email sent", failed: "Email failed", skipped: "Email skipped" };
export default function ClientLeadDelivery({ lead, api, editable, onDelivery }: { lead: Lead; api: BusinessApi; editable: boolean; onDelivery: (delivery: ClientDelivery) => void }) {
  const delivery = lead.clientDelivery;
  const recipient = delivery?.current_recipient_email === undefined ? delivery?.recipient_email : delivery.current_recipient_email;
  const [confirmed, setConfirmed] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const intention = useRef<{ requestId: string; recipient: string } | null>(null), active = useRef<AbortController | null>(null);
  useEffect(() => () => active.current?.abort(), []);
  useEffect(() => { active.current?.abort(); active.current = null; intention.current = null; setBusy(false); setConfirmed(false); setError(""); setNotice(""); }, [lead.id, recipient]);
  if (!delivery) return null;
  const canRequest = !!recipient && (delivery.can_resend || intention.current?.recipient === recipient);
  const send = async () => {
    if (active.current || !confirmed || !editable || !canRequest || !recipient) return;
    const controller = new AbortController(); active.current = controller; setBusy(true); setError(""); setNotice("");
    if (!intention.current) intention.current = { requestId: crypto.randomUUID(), recipient };
    const request = intention.current;
    try {
      const result = await api.sendLeadToClient(lead.id, request.requestId, request.recipient, controller.signal);
      if (!controller.signal.aborted) { onDelivery(result); setNotice(`Delivery request saved for ${result.recipient_email}. Check its email status after refreshing.`); intention.current = null; setConfirmed(false); }
    } catch (error) { if (!controller.signal.aborted) setError(`${error instanceof Error ? error.message : "Delivery could not be confirmed."} Retry checks the same request and avoids a second email.`); }
    finally { if (active.current === controller) active.current = null; if (!controller.signal.aborted) setBusy(false); }
  };
  return <section className="business-client-delivery" aria-label="Client lead email"><h4>{delivery.recipient_email === null ? "Ready to send to client" : clientDeliveryLabels[delivery.state]}</h4><p>{delivery.client_name || delivery.current_client_name || "Client"} · {delivery.recipient_email || recipient}</p>
    {delivery.sent_at && <small>Provider accepted {new Date(delivery.sent_at).toLocaleString()}.</small>}
    {delivery.reason && <p className="business-subtle">{delivery.reason}</p>}
    <p className="business-subtle">This inquiry is saved in your account. Email sent means the provider accepted it; inbox placement can’t be guaranteed.</p>
    {delivery.recipient_email && recipient && recipient !== delivery.recipient_email && <p className="business-notice">The listing contact changed. A new email will go to {delivery.current_client_name || "the current client"} at {recipient}. The status above describes the previous recipient.</p>}
    {editable && <><label className="business-check"><input type="checkbox" checked={confirmed} disabled={busy || !canRequest} onChange={event => setConfirmed(event.target.checked)} /> Email this inquiry to {recipient || "the saved listing client"}</label><button disabled={busy || !confirmed || !canRequest} onClick={() => void send()}>{busy ? "Requesting…" : error ? "Retry same delivery request" : delivery.recipient_email === null ? "Send to client" : "Resend to client"}</button>{!canRequest && <p className="business-subtle">{recipient ? "Refresh after the current delivery or resend cooldown finishes." : "Enable a client lead email on this listing before sending."}</p>}</>}
    {error && <p role="alert" className="business-notice error">{error}</p>}{notice && <p role="status" className="business-notice success">{notice}</p>}
  </section>;
}
