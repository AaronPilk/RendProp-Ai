import { HttpError } from "../_shared/http.ts";
import { deleteRecordedUpload } from "../_shared/r2.ts";
import {
  row,
  type UploadAdmin,
  type UploadRow,
  uploadRPC,
} from "./transport.ts";
import { UUID } from "./gateway_contract.ts";

/** Bounded, retryable service-only sweep. It reports failures, not fake cleanup
 * success; keys come exclusively from the DB cleanup lease. No broad listing. */
export async function sweepUploads(
  admin: UploadAdmin,
  remove: (op: UploadRow) => Promise<boolean> = deleteRecordedUpload,
) {
  const batch = row(await uploadRPC(admin, "upload_maintenance_batch", {}));
  for (const field of ["expire", "cleanup"]) {
    const ids = batch[field];
    if (
      !Array.isArray(ids) || ids.length > 16 ||
      new Set(ids).size !== ids.length || ids.some((id) =>
        typeof id !== "string" || !UUID.test(id)
      )
    ) {
      throw new HttpError(503, "Invalid bounded maintenance inventory");
    }
  }
  const receipt = {
    expired: 0,
    cleaned: 0,
    failed: 0,
    pending: Boolean(
      (batch.expire as string[]).length || (batch.cleanup as string[]).length,
    ),
  };
  for (const id of batch.expire as string[]) {
    try {
      await uploadRPC(admin, "expire_upload_reservation", { p_asset: id });
      receipt.expired++;
    } catch {
      receipt.failed++;
    }
  }
  const ids = batch.cleanup as string[];
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(4, ids.length) }, async () => {
      while (cursor < ids.length) {
        const id = ids[cursor++], claim = crypto.randomUUID();
        let op: UploadRow | undefined;
        try {
          op = row(
            await uploadRPC(admin, "claim_upload_cleanup", {
              p_operation: id,
              p_claim: claim,
            }),
          );
          if (
            op.id !== id || op.state !== "cleaning" ||
            op.cleanup_claim !== claim
          ) throw new HttpError(503, "Cleanup lease receipt mismatch");
          const deleted = await remove(op);
          await uploadRPC(admin, "finish_upload_cleanup", {
            p_operation: id,
            p_claim: claim,
            p_deleted: deleted,
          });
          if (deleted) receipt.cleaned++;
          else receipt.failed++;
        } catch {
          receipt.failed++;
          if (op) {
            try {
              await uploadRPC(admin, "finish_upload_cleanup", {
                p_operation: id,
                p_claim: claim,
                p_deleted: false,
              });
            } catch { /* Lease remains durable. */ }
          }
        }
      }
    }),
  );
  return receipt;
}
