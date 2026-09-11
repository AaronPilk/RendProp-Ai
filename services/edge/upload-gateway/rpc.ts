import {
  gatewayOrigin,
  TransportError,
} from "../../supabase/functions/uploads/gateway_contract.ts";

/** Fixed destination; never accepts a caller URL, credentials, RPC name or key. */
export function stateClient(
  origin: string | undefined,
  allowed: string | undefined,
  secret: string | undefined,
) {
  const base = gatewayOrigin(origin, allowed);
  if (
    !secret || secret.length < 16 || secret.length > 8192 ||
    secret !== secret.trim()
  ) throw new TransportError(503, "Upload state is not configured");
  return async (
    name: "claim_upload_operation" | "finish_upload_operation",
    args: Record<string, unknown>,
  ) => {
    const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
      method: "POST",
      // workerd does not implement redirect:"error". Manual mode never follows
      // the location; the non-2xx check below rejects it without forwarding keys.
      redirect: "manual",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${secret}`,
        apikey: secret,
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.body) {
      throw new TransportError(503, "Upload state returned no receipt");
    }
    const reader = response.body.getReader();
    let size = 0, text = "";
    const decoder = new TextDecoder();
    try {
      while (true) {
        const r = await reader.read();
        if (r.done) break;
        size += r.value.byteLength;
        if (size > 32_768) {
          throw new TransportError(503, "Upload receipt exceeds its bound");
        }
        text += decoder.decode(r.value, { stream: true });
      }
      text += decoder.decode();
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
    if (!response.ok) {
      const code = /RP(400|403|404|409|429|503):/.exec(text)?.[1];
      throw new TransportError(
        code ? Number(code) : 503,
        "Upload authority unavailable; retry receipt or cancel",
      );
    }
    let value: unknown;
    try {
      value = JSON.parse(text);
    } catch {
      throw new TransportError(503, "Invalid upload receipt");
    }
    if (value === null) {
      throw new TransportError(503, "Upload receipt is missing");
    }
    return value;
  };
}
