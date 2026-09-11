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

/** Actual HTTP behavior, tested with fixture services; no production fallback. */
export async function handleUpload(
  request: Request,
  services: GatewayDependencies,
): Promise<Response> {
  let op: GatewayOperation | undefined, claim: string | undefined;
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
    timer = setTimeout(interrupted, TRANSFER_DEADLINE_MS);
    if (request.signal.aborted) interrupted();
    const fixed = services.fixedStream(op.bytes);
    // Both promises are observed immediately. forwardExactBody holds the last
    // byte until EOF, so even a sink that commits at exactly Content-Length
    // cannot accept an oversized body's prefix.
    const pump = forwardExactBody(
      request.body,
      fixed.writable,
      op.bytes,
      cancellation.signal,
      (error) => cancellation.abort(error),
    );
    const storage = services.write(op, fixed.readable).catch((error) => {
      cancellation.abort(error);
      throw error;
    });
    const aborted = new Promise<never>((_, reject) => {
      if (cancellation.signal.aborted) reject(cancellation.signal.reason);
      else {cancellation.signal.addEventListener("abort", () =>
          reject(cancellation.signal.reason), { once: true });}
    });
    const results = await Promise.race([
      Promise.allSettled([pump, storage]),
      aborted,
    ]);
    if (results[0].status === "rejected") throw results[0].reason;
    if (results[1].status === "rejected") throw results[1].reason;
    const etag = results[1].value;
    if (!etag || etag.length > 256) {
      throw new TransportError(502, "Storage returned no valid ETag");
    }
    await services.finish(op.id, claim, "stored", etag, op.content_type);
    return new Response(null, {
      status: 200,
      headers: { ...headers, ETag: etag },
    });
  } catch (error) {
    cancellation.abort(error);
    if (op?.dispatch && claim) {
      // A timeout/lost reply may already have written bytes. Never release its
      // reservation, never send a second storage write from this handler.
      try {
        await services.finish(
          op.id,
          claim,
          error instanceof TransportError && error.status < 500
            ? "rejected"
            : "uncertain",
          null,
        );
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
