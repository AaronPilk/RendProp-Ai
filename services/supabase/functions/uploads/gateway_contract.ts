// Shared browser-independent capability contract. No environment reads/I/O.
export const MAX_TRANSFER_BYTES = 64 * 1024 * 1024;
export const TRANSFER_DEADLINE_MS = 10 * 60 * 1000;
export const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export class TransportError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
export function gatewayOrigin(
  origin: string | undefined,
  allowlisted: string | undefined,
): string {
  if (!origin || origin !== allowlisted) {
    throw new TransportError(
      503,
      "Upload gateway is not configured and allowlisted",
    );
  }
  let u: URL;
  try {
    u = new URL(origin);
  } catch {
    throw new TransportError(503, "Invalid upload gateway origin");
  }
  if (
    u.origin !== origin || u.protocol !== "https:" || u.username ||
    u.password || u.port ||
    !/^[a-z0-9.-]+\.[a-z]{2,}$/.test(u.hostname)
  ) throw new TransportError(503, "Invalid upload gateway origin");
  return origin;
}
const encoder = new TextEncoder();
async function signingKey(secret: string | undefined) {
  if (
    !secret || encoder.encode(secret).length < 32 || secret.length > 256 ||
    secret !== secret.trim()
  ) {
    throw new TransportError(
      503,
      "Upload capability signing is not configured",
    );
  }
  return await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}
function payload(id: string, expiry: number) {
  if (!UUID.test(id) || !Number.isSafeInteger(expiry) || expiry <= 0) {
    throw new TransportError(400, "Invalid upload capability");
  }
  return encoder.encode(`rendprop-upload-v2\nPUT\n${id}\n${expiry}`);
}
export async function uploadCapability(
  origin: string,
  secret: string | undefined,
  id: string,
  expiry: number,
) {
  const bytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      await signingKey(secret),
      payload(id, expiry),
    ),
  );
  const signature = Array.from(bytes, (b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${origin}/v2/${id}?expires=${expiry}&signature=${signature}`;
}
export async function verifyCapability(
  url: URL,
  origin: string,
  secret: string | undefined,
  now: number,
): Promise<string> {
  if (
    url.origin !== origin || url.hash ||
    !/^\/v2\/[0-9a-f-]{36}$/.test(url.pathname) ||
    [...url.searchParams].length !== 2 ||
    url.searchParams.getAll("expires").length !== 1 ||
    url.searchParams.getAll("signature").length !== 1
  ) throw new TransportError(403, "Invalid upload capability");
  const id = url.pathname.slice(4),
    rawExpiry = url.searchParams.get("expires") ?? "",
    hex = url.searchParams.get("signature") ?? "";
  if (!/^[1-9][0-9]{0,12}$/.test(rawExpiry) || !/^[a-f0-9]{64}$/.test(hex)) {
    throw new TransportError(403, "Invalid upload capability");
  }
  const expiry = Number(rawExpiry);
  if (expiry <= now || expiry > now + 48 * 3600) {
    throw new TransportError(
      403,
      "Upload capability expired or outside lifetime",
    );
  }
  const signature = Uint8Array.from(hex.match(/../g)!, (b) => parseInt(b, 16));
  if (
    !await crypto.subtle.verify(
      "HMAC",
      await signingKey(secret),
      signature,
      payload(id, expiry),
    )
  ) {
    throw new TransportError(403, "Invalid upload capability");
  }
  return id;
}

/** Stream without whole-file buffering. Withhold the last byte until true EOF:
 * a lying/oversized source must never give R2 a complete expected-length prefix.
 * The production sink is also a FixedLengthStream; it independently refuses
 * both short and long bodies. No body retry occurs inside this function. */
export async function forwardExactBody(
  body: ReadableStream<Uint8Array>,
  sink: WritableStream<Uint8Array>,
  expected: number,
  signal: AbortSignal,
  reportFailure?: (error: unknown) => void,
): Promise<void> {
  if (
    !Number.isSafeInteger(expected) || expected < 1 ||
    expected > MAX_TRANSFER_BYTES
  ) throw new TransportError(413, "Invalid transfer length");
  const reader = body.getReader(), writer = sink.getWriter();
  let received = 0, last: Uint8Array | undefined;
  const abort = () => {
    void reader.cancel(signal.reason).catch(() => {});
    void writer.abort(signal.reason).catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw new TransportError(408, "Upload interrupted");
    for (;;) {
      const { done, value } = await reader.read();
      if (signal.aborted) throw new TransportError(408, "Upload interrupted");
      if (done) break;
      if (
        !(value instanceof Uint8Array) || value.byteLength > expected - received
      ) throw new TransportError(413, "Upload exceeds its reserved byte count");
      received += value.byteLength;
      if (!value.byteLength) continue;
      if (received === expected) {
        if (value.byteLength > 1) {
          await writer.write(value.subarray(0, value.byteLength - 1));
        }
        last = value.slice(-1); // hold exactly one byte, not a reference to a large network chunk
      } else await writer.write(value);
    }
    if (received !== expected || !last) {
      throw new TransportError(
        400,
        "Upload ended before its reserved byte count",
      );
    }
    await writer.write(last);
    await writer.close();
  } catch (error) {
    // Report the local validation error before an R2/service boundary can
    // serialize its abort into a generic Error and win the caller's race.
    reportFailure?.(error);
    await Promise.allSettled([reader.cancel(error), writer.abort(error)]);
    throw error;
  } finally {
    signal.removeEventListener("abort", abort);
    reader.releaseLock();
    writer.releaseLock();
  }
}
