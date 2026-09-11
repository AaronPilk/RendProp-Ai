/// <reference path="./worker-configuration.d.ts" />
import { handleUpload } from "./handler.ts";
import { stateClient } from "./rpc.ts";

// No S3 bearer URL or caller bucket/key reaches this adapter. Both destinations
// and the signing secret must be explicitly configured; defaults are inert.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return await handleUpload(request, {
      origin: env.UPLOAD_GATEWAY_ORIGIN,
      allowedOrigin: env.UPLOAD_GATEWAY_ALLOWED_ORIGIN,
      secret: env.UPLOAD_CAPABILITY_SECRET,
      now: () => Math.floor(Date.now() / 1000),
      claim: (id, claim) =>
        stateClient(
          env.SUPABASE_ORIGIN,
          env.SUPABASE_ALLOWED_ORIGIN,
          env.SUPABASE_SERVICE_ROLE_KEY,
        )("claim_upload_operation", { p_operation: id, p_claim: claim }),
      finish: async (id, claim, result, etag, contentType) => {
        await stateClient(
          env.SUPABASE_ORIGIN,
          env.SUPABASE_ALLOWED_ORIGIN,
          env.SUPABASE_SERVICE_ROLE_KEY,
        )("finish_upload_operation", {
          p_operation: id,
          p_claim: claim,
          p_result: result,
          p_etag: etag,
          p_upload_id: null,
          p_content_type: contentType ?? null,
        });
      },
      fixedStream: (length) => new FixedLengthStream(length),
      write: async (op, body) => {
        const bucket = op.bucket === "uploads" ? env.UPLOADS : env.RENDERS;
        if (op.kind === "part") {
          const etag =
            (await bucket.resumeMultipartUpload(op.object_key, op.upload_id!)
              .uploadPart(op.part, body)).etag;
          return etag.startsWith('"') ? etag : `"${etag}"`;
        }
        const result = await bucket.put(op.object_key, body, {
          httpMetadata: { contentType: op.content_type },
        });
        if (!result) throw new Error("Storage returned no upload receipt");
        return result.httpEtag;
      },
    });
  },
} satisfies ExportedHandler<Env>;
