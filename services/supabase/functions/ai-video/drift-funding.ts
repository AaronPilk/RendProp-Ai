// A manual recheck after HOLD is a new paid operation. The durable SQL journal
// allocates its identity; client nonces and clocks never reopen running checks.
import { fundingContext, type FundingContext } from "../_shared/funded-serving.ts";
import { HttpError, throwRpc } from "../_shared/http.ts";

export interface DriftCheck {
  id: string;
  funding: FundingContext | null;
  replay: Record<string, unknown> | null;
}
const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

export async function beginDriftCheck(args: {
  actor: string; orgId: string; requestId: string; kind: "reel" | "aerial";
  sourceHash: string; listingId: string | null; req: Request; input: unknown;
  rpc: FundingContext["rpc"];
}): Promise<DriftCheck> {
  const result = await args.rpc("app_video_drift_check_begin", {
    p_actor: args.actor, p_org: args.orgId, p_request: args.requestId,
    p_feature: args.kind, p_source_sha256: args.sourceHash, p_listing: args.listingId,
  });
  if (result.error) throwRpc(result.error.message);
  const data = result.data as { id?: unknown; replay?: unknown; result?: unknown } | null;
  if (!data || typeof data.id !== "string" || !UUID.test(data.id)) {
    throw new HttpError(503, "This quality check could not be journaled safely. Retry shortly.", "upstream");
  }
  if (data.replay === true) {
    if (!data.result || typeof data.result !== "object" || Array.isArray(data.result)) {
      throw new HttpError(503, "The saved quality check could not be read. Retry shortly.", "upstream");
    }
    return { id: data.id, funding: null, replay: data.result as Record<string, unknown> };
  }
  const headers = new Headers(args.req.headers);
  headers.set("idempotency-key", `drift-check:${data.id}`);
  try {
    const funding = await fundingContext(args.actor, args.orgId,
      new Request(args.req.url, { method: args.req.method, headers }), args.input, args.rpc);
    return { id: data.id, funding, replay: null };
  } catch (error) {
    // No judge dispatch has happened. The old operation remains fenced; the
    // journal permits a later manual recheck with a new paid identity.
    await finishDriftCheck(args.rpc, args.actor, args.orgId, data.id, "hold", null);
    throw error;
  }
}

export async function finishDriftCheck(rpc: FundingContext["rpc"], actor: string, orgId: string,
  id: string, action: "accept" | "retry" | "refuse" | "hold", result: Record<string, unknown> | null): Promise<void> {
  const saved = await rpc("app_video_drift_check_finish", {
    p_actor: actor, p_org: orgId, p_check: id, p_action: action, p_result: result,
  });
  if (saved.error) throwRpc(saved.error.message);
  if (saved.data !== true) throw new HttpError(503,
    "This quality check could not be saved safely. Retry this saved clip shortly.", "upstream");
}
