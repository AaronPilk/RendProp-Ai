import { HttpError } from "../_shared/http.ts";
import { gatewayOrigin, uploadCapability } from "./gateway_contract.ts";
import {
  headObject,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
  recoverMultipartInitialization,
  recoverMultipartPart,
} from "../_shared/r2.ts";
import { baseMediaType } from "./content_type.ts";

export type UploadRow = Record<string, unknown>;
// Structural service-client surface, shared with fixture clients. Never a user
// client: the new tables/RPCs are explicitly service_role-only with RLS enabled.
export interface UploadAdmin {
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { message?: string } | null }>;
}
export async function uploadRPC(
  admin: UploadAdmin,
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await admin.rpc(name, args);
  if (error) {
    const code = /RP(400|403|404|409|429|503):/.exec(error.message ?? "")?.[1];
    throw new HttpError(
      code ? Number(code) : 503,
      code
        ? (error.message ?? "").replace(/^.*RP\d+:\s*/, "")
        : "Durable upload state unavailable — retry",
    );
  }
  if (data == null) throw new HttpError(503, "Durable upload receipt missing");
  return data;
}
export function row(value: unknown): UploadRow {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(503, "Invalid durable upload receipt");
  }
  return value as UploadRow;
}
export function transportConfiguration() {
  let origin: string;
  try {
    origin = gatewayOrigin(
      Deno.env.get("UPLOAD_GATEWAY_ORIGIN"),
      Deno.env.get("UPLOAD_GATEWAY_ALLOWED_ORIGIN"),
    );
  } catch {
    throw new HttpError(
      503,
      "Upload gateway is not configured and allowlisted",
    );
  }
  const secret = Deno.env.get("UPLOAD_CAPABILITY_SECRET");
  if (
    !secret || secret.length < 32 || secret.length > 256 ||
    secret !== secret.trim()
  ) throw new HttpError(503, "Upload signing is not configured");
  return { origin, secret };
}
export async function reserveAssets(
  admin: UploadAdmin,
  actor: string,
  assets: UploadRow[],
): Promise<UploadRow[]> {
  const value = await uploadRPC(admin, "reserve_upload_assets", {
    p_actor: actor,
    p_assets: assets,
  });
  if (!Array.isArray(value) || value.length !== assets.length) {
    throw new HttpError(503, "Incomplete upload reservation receipt");
  }
  return value.map(row);
}
export async function planOperation(
  admin: UploadAdmin,
  asset: string,
  kind: string,
  part = 0,
) {
  const plan = async () =>
    row(
      await uploadRPC(admin, "plan_upload_operation", {
        p_asset: asset,
        p_kind: kind,
        p_part: part,
      }),
    );
  let op = await plan();
  if (["dispatching", "uncertain"].includes(String(op.state))) {
    op = await recoverRecordedOperation(admin, op);
    // A transfer the server observed absent comes back `rejected` (0042); the
    // same plan call re-issues it in place: same row, same key, one more attempt.
    if (op.state === "rejected") op = await plan();
  }
  return op;
}
/** Only read the server-journaled identity. Missing/ambiguous storage never
 * creates another write or refunds the spent byte authority. For the
 * client-driven single/part transfers a clean miss on the registered key/part
 * is itself the observation the journal needs: past the write deadline it
 * retires the dispatch as `rejected`, which plan may then re-issue. Recorded
 * init/copy/assemble operations never take that path. */
export async function recoverRecordedOperation(
  admin: UploadAdmin,
  op: UploadRow,
): Promise<UploadRow> {
  const bucket = op.bucket === "renders"
    ? R2_BUCKET_RENDERS
    : R2_BUCKET_UPLOADS;
  let etag: string | null = null,
    uploadId: string | null = null,
    contentType: string | null = null,
    absent = false;
  if (op.kind === "init") {
    uploadId = await recoverMultipartInitialization(
      bucket,
      String(op.object_key),
    );
    if (uploadId) etag = "multipart-initialized";
  } else if (op.kind === "part") {
    etag = await recoverMultipartPart({
      bucket,
      key: String(op.object_key),
      uploadId: String(op.upload_id),
      part: Number(op.part),
      bytes: Number(op.bytes),
    });
    // A listed part of the wrong size throws inside the helper; only an
    // unlisted part number is a miss.
    absent = etag === null;
  } else if (["single", "copy", "assemble"].includes(String(op.kind))) {
    const head = await headObject(bucket, String(op.object_key));
    contentType = baseMediaType(head.contentType);
    const allowed = op.asset_kind === "video"
      ? ["video/mp4", "video/quicktime", "video/x-m4v"]
      : op.bucket === "renders"
      ? ["image/jpeg", "image/png", "image/webp"]
      : ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"];
    absent = !head.exists;
    if (
      head.exists && head.bytes === Number(op.expected_bytes) &&
      allowed.includes(contentType) &&
      (op.content_type_declared !== true || contentType === op.content_type)
    ) etag = head.etag;
  } else throw new HttpError(503, "Unknown recovery operation");
  if (!etag) {
    if (absent && ["single", "part"].includes(String(op.kind))) {
      const retired = row(
        await uploadRPC(admin, "recover_upload_operation", {
          p_operation: op.id,
          p_etag: null,
          p_upload_id: null,
          p_content_type: null,
        }),
      );
      // Still inside its write window: the row comes back unchanged.
      if (retired.state === "rejected") return retired;
    }
    throw new HttpError(
      503,
      "Stored receipt is not yet provable; retry later or cancel. No new write was issued.",
    );
  }
  return row(
    await uploadRPC(admin, "recover_upload_operation", {
      p_operation: op.id,
      p_etag: etag,
      p_upload_id: uploadId,
      p_content_type: contentType,
    }),
  );
}
export async function transferURL(
  admin: UploadAdmin,
  asset: string,
  kind: "single" | "part",
  part = 0,
) {
  const { origin, secret } = transportConfiguration(),
    op = await planOperation(admin, asset, kind, part);
  if (op.state === "rejected" && op.attempts_exhausted === true) {
    // Terminal for this ticket by design: the journal refused another attempt.
    // A 409 tells the client to abort and re-ticket instead of polling a 503.
    throw new HttpError(
      409,
      "This upload used all of its transfer attempts — abort it and create a new ticket",
    );
  }
  if (!["planned", "stored"].includes(String(op.state))) {
    throw new HttpError(
      503,
      "Transfer needs recovery or cancellation; no second physical write is authorized",
    );
  }
  const expiry = Math.floor(new Date(String(op.expires_at)).getTime() / 1000);
  return await uploadCapability(origin, secret, String(op.id), expiry);
}
/** One durable claim authorizes one external operation. A lost response never
 * grants another attempt or refunds bytes; recovery inspects the recorded key. */
export async function recordedOperation(
  admin: UploadAdmin,
  asset: string,
  kind: "init" | "copy" | "assemble",
  execute: (
    op: UploadRow,
  ) => Promise<{ etag: string; uploadId?: string; contentType?: string }>,
): Promise<UploadRow> {
  const planned = await planOperation(admin, asset, kind),
    claim = crypto.randomUUID();
  const op = row(
    await uploadRPC(admin, "claim_upload_operation", {
      p_operation: planned.id,
      p_claim: claim,
    }),
  );
  if (op.dispatch === false) return op;
  if (op.dispatch !== true || op.id !== planned.id) {
    throw new HttpError(503, "Invalid operation dispatch receipt");
  }
  try {
    const result = await execute(op);
    return row(
      await uploadRPC(admin, "finish_upload_operation", {
        p_operation: op.id,
        p_claim: claim,
        p_result: "stored",
        p_etag: result.etag,
        p_upload_id: result.uploadId ?? null,
        p_content_type: result.contentType ?? null,
      }),
    );
  } catch (error) {
    try {
      await uploadRPC(admin, "finish_upload_operation", {
        p_operation: op.id,
        p_claim: claim,
        p_result: "uncertain",
        p_etag: null,
        p_upload_id: null,
      });
    } catch {
      /* The dispatch record is durable even if this acknowledgement fails. */
    }
    throw error;
  }
}
export async function confirmedTransfers(
  admin: UploadAdmin,
  asset: string,
): Promise<UploadRow[]> {
  const value = await uploadRPC(admin, "confirmed_upload_transfers", {
    p_asset: asset,
  });
  if (!Array.isArray(value)) {
    throw new HttpError(503, "Invalid transfer manifest receipt");
  }
  return value.map(row);
}
export async function settleReservation(
  admin: UploadAdmin,
  asset: string,
  complete: boolean,
  operation: string | null = null,
  metadata: UploadRow = {},
) {
  return row(
    await uploadRPC(admin, "settle_upload_reservation", {
      p_asset: asset,
      p_complete: complete,
      p_operation: operation,
      p_metadata: metadata,
    }),
  );
}
