import {
  forwardExactBody,
  gatewayOrigin,
  MAX_TRANSFER_BYTES,
  TRANSFER_DEADLINE_MS,
  TransportError,
  UUID,
  verifyCapability,
} from "../../supabase/functions/uploads/gateway_contract.ts";

export interface GatewayOperation {
  id: string;
  asset_id: string;
  kind: "single" | "part";
  bucket: "uploads" | "renders";
  object_key: string;
  upload_id: string | null;
  part: number;
  bytes: number;
  content_type: string;
  dispatch: boolean;
  etag: string | null;
  content_type_declared: boolean;
  asset_kind: "video" | "photo";
}
export interface GatewayDependencies {
  origin: string | undefined;
  allowedOrigin: string | undefined;
  secret: string | undefined;
  now(): number;
  /** Fixture seam only: production keeps the contract's 10-minute deadline. */
  deadlineMs?: number;
  claim(id: string, claim: string): Promise<unknown>;
  finish(
    id: string,
    claim: string,
    result: "stored" | "uncertain" | "rejected",
    etag: string | null,
    contentType?: string,
  ): Promise<void>;
  fixedStream(
    length: number,
  ): {
    readable: ReadableStream<Uint8Array>;
    writable: WritableStream<Uint8Array>;
  };
  write(
    operation: GatewayOperation,
    body: ReadableStream<Uint8Array>,
  ): Promise<string>;
}
export function operation(value: unknown): GatewayOperation {
  if (!value || typeof value !== "object") {
    throw new TransportError(503, "Invalid transfer authority");
  }
  const v = value as Record<string, unknown>;
  if (
    typeof v.id !== "string" || !UUID.test(v.id) ||
    typeof v.asset_id !== "string" || !UUID.test(v.asset_id) ||
    !["single", "part"].includes(String(v.kind)) ||
    !["uploads", "renders"].includes(String(v.bucket)) ||
    typeof v.object_key !== "string" || v.object_key.length > 1024 ||
    v.object_key.includes("..") ||
    !v.object_key.startsWith(
      v.kind === "single" ? "_staging/" : `${v.bucket}/`,
    ) ||
    !Number.isSafeInteger(v.bytes) || Number(v.bytes) < 1 ||
    Number(v.bytes) > MAX_TRANSFER_BYTES ||
    typeof v.content_type !== "string" ||
    !/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(v.content_type) ||
    typeof v.content_type_declared !== "boolean" ||
    !["video", "photo"].includes(String(v.asset_kind)) ||
    typeof v.dispatch !== "boolean" ||
    !(v.etag === null ||
      typeof v.etag === "string" && v.etag.length > 0 &&
        v.etag.length <= 256) ||
    !Number.isInteger(v.part) ||
    (v.kind === "single"
      ? v.part !== 0
      : Number(v.part) < 1 || Number(v.part) > 384) ||
    !(v.upload_id === null ||
      typeof v.upload_id === "string" && v.upload_id.length > 0 &&
        v.upload_id.length <= 2048) ||
    (v.kind === "part" && !v.upload_id)
  ) throw new TransportError(503, "Invalid transfer authority");
  return {
    id: v.id,
    asset_id: v.asset_id,
    kind: v.kind === "single" ? "single" : "part",
    bucket: v.bucket === "uploads" ? "uploads" : "renders",
    object_key: v.object_key,
    upload_id: typeof v.upload_id === "string" ? v.upload_id : null,
    part: Number(v.part),
    bytes: Number(v.bytes),
    content_type: v.content_type,
    content_type_declared: v.content_type_declared,
    asset_kind: v.asset_kind === "video" ? "video" : "photo",
    dispatch: v.dispatch,
    etag: typeof v.etag === "string" ? v.etag : null,
  };
}
const headers = {
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-expose-headers": "ETag",
};
function response(status: number, message: string) {
  return Response.json({ error: message }, { status, headers });
}

/** How long a lost body race waits for the storage write to report before the
 * journal is told anything. A sink that already took every byte settles in
 * well under this; one whose stream was aborted rejects at once. */
const STORAGE_SETTLE_MS = 2000;
async function settledEtag(
  storage: Promise<string> | undefined,
  ms: number,
): Promise<string | null> {
  if (!storage) return null;
  let grace: ReturnType<typeof setTimeout> | undefined;
  try {
    const etag = await Promise.race([
      storage.then((value) => value, () => null),
      new Promise<null>((done) => grace = setTimeout(() => done(null), ms)),
    ]);
    return typeof etag === "string" && etag.length > 0 && etag.length <= 256
      ? etag
      : null;
  } finally {
    if (grace !== undefined) clearTimeout(grace);
  }
}

/** Actual HTTP behavior, tested with fixture services; no production fallback. */
export async function handleUpload(
  request: Request,
  services: GatewayDependencies,
): Promise<Response> {
  let op: GatewayOperation | undefined, claim: string | undefined;
  // Set once the body pump is created: from then on bytes may have reached the
  // sink, and only the sink's own verdict or a later read-only observation can
  // say whether an object exists. `reported` marks the stored receipt attempt.
  let bodyStarted = false, reported = false;
  let storage: Promise<string> | undefined;
  const cancellation = new AbortController();
  const interrupted = () =>
    cancellation.abort(new TransportError(408, "Upload interrupted"));
  request.signal.addEventListener("abort", interrupted, { once: true });
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const origin = gatewayOrigin(services.origin, services.allowedOrigin);
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          ...headers,
          "access-control-allow-methods": "PUT",
          "access-control-allow-headers": "Content-Type,Content-Length",
        },
      });
    }
    if (request.method !== "PUT") return response(405, "PUT required");
    const id = await verifyCapability(
      new URL(request.url),
      origin,
      services.secret,
      services.now(),
    );
    if (!request.body || request.headers.has("content-encoding")) {
      throw new TransportError(400, "A non-encoded upload body is required");
    }
    const length = request.headers.get("content-length");
    if (
      length !== null &&
      (!/^[1-9][0-9]{0,8}$/.test(length) || Number(length) > MAX_TRANSFER_BYTES)
    ) {
      throw new TransportError(
        413,
        "Upload Content-Length exceeds the transfer limit",
      );
    }
    claim = crypto.randomUUID();
    op = operation(await services.claim(id, claim));
    if (op.id !== id) {
      throw new TransportError(503, "Transfer identity mismatch");
    }
    if (!op.dispatch) {
      if (!op.etag) {
        throw new TransportError(503, "Stored transfer receipt is incomplete");
      }
      await request.body.cancel();
      return new Response(null, {
        status: 200,
        headers: { ...headers, ETag: op.etag },
      });
    }
    // The reservation-dependent header checks. The gateway's only journal verbs
    // are claim and finish (index.ts wiring), so the exact length/type can only
    // be known after the claim; they are settled here before a single body byte
    // is read, and a mismatch closes as a pre-body `rejected` verdict that 0042
    // re-plans on the same ticket at no net byte cost.
    if (length !== null && Number(length) !== op.bytes) {
      throw new TransportError(
        400,
        "Upload length does not match its reservation",
      );
    }
    const type = request.headers.get("content-type");
    if (op.kind === "single") {
      const allowed = op.asset_kind === "video"
        ? ["video/mp4", "video/quicktime", "video/x-m4v"]
        : op.bucket === "renders"
        ? ["image/jpeg", "image/png", "image/webp"]
        : ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"];
      if (
        !type || !allowed.includes(type) ||
        op.content_type_declared && type !== op.content_type
      ) {
        throw new TransportError(
          400,
          "Upload type does not match its reservation",
        );
      }
      op.content_type = type;
    }
    // A client that is already gone has sent nothing to storage yet.
    if (request.signal.aborted) {
      throw new TransportError(408, "Upload interrupted");
    }
    timer = setTimeout(
      interrupted,
      services.deadlineMs ?? TRANSFER_DEADLINE_MS,
    );
    const fixed = services.fixedStream(op.bytes);
    // Both promises are observed immediately. forwardExactBody holds the last
    // byte until EOF, so even a sink that commits at exactly Content-Length
    // cannot accept an oversized body's prefix.
    bodyStarted = true;
    const pump = forwardExactBody(
      request.body,
      fixed.writable,
      op.bytes,
      cancellation.signal,
      (error) => cancellation.abort(error),
    );
    storage = services.write(op, fixed.readable);
    const guarded = storage.catch((error) => {
      cancellation.abort(error);
      throw error;
    });
    const aborted = new Promise<never>((_, reject) => {
      if (cancellation.signal.aborted) reject(cancellation.signal.reason);
      else {cancellation.signal.addEventListener("abort", () =>
          reject(cancellation.signal.reason), { once: true });}
    });
    const results = await Promise.race([
      Promise.allSettled([pump, guarded]),
      aborted,
    ]);
    if (results[0].status === "rejected") throw results[0].reason;
    if (results[1].status === "rejected") throw results[1].reason;
    const etag = results[1].value;
    if (!etag || etag.length > 256) {
      throw new TransportError(502, "Storage returned no valid ETag");
    }
    reported = true;
    await services.finish(op.id, claim, "stored", etag, op.content_type);
    return new Response(null, {
      status: 200,
      headers: { ...headers, ETag: etag },
    });
  } catch (error) {
    cancellation.abort(error);
    if (op?.dispatch && claim) {
      // The race can be lost a hair after the sink took the whole body (the
      // deadline or the client's abort firing while storage finalizes). Let the
      // write report for a bounded moment: a receipt it returns is as good as
      // one from the happy path, and it is never followed by a second write.
      const landed = bodyStarted && !reported
        ? await settledEtag(storage, STORAGE_SETTLE_MS)
        : null;
      if (landed) {
        try {
          await services.finish(
            op.id,
            claim,
            "stored",
            landed,
            op.content_type,
          );
          return new Response(null, {
            status: 200,
            headers: { ...headers, ETag: landed },
          });
        } catch {
          /* The receipt exists in storage; a later HEAD recovers it. */
        }
      }
      // Verdict for the journal. `rejected` means no object can exist: nothing
      // was pumped yet, or the pump itself refused the body (short/oversized)
      // while still holding the final byte back from the sink. Everything else
      // after bytes started flowing (a cut, the deadline, storage/service
      // errors) may have landed and stays `uncertain` for read-only recovery.
      // Neither verdict releases the reservation or sends a second write here.
      const verdict = !bodyStarted ||
          error instanceof TransportError &&
            (error.status === 400 || error.status === 413)
        ? "rejected"
        : "uncertain";
      try {
        await services.finish(op.id, claim, verdict, null);
      } catch {
        /* The pre-dispatch journal survives even if this update fails. */
      }
    }
    if (request.body && !request.body.locked) {
      await request.body.cancel().catch(() => {});
    }
    return error instanceof TransportError
      ? response(error.status, error.message)
      : response(
        503,
        "Upload state is uncertain; retry the receipt or cancel the upload",
      );
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    request.signal.removeEventListener("abort", interrupted);
  }
}
