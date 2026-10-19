import { assert, json } from "../_shared/http.ts";
import { falLegacyReceipt, falLegacyReceiptMatchesModel } from "../_shared/providers/fal.ts";
import type { JobRef } from "../_shared/providers/types.ts";
import type { RouterJobToken } from "../_shared/providers/jobtoken.ts";

type Row = Record<string, unknown>;
type RPCResult = { data: unknown; error: unknown };
type RPC = (name: string, args: Row) => Promise<RPCResult>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const row = (value: unknown): value is Row => !!value && typeof value === "object" && !Array.isArray(value);

/** A complete provider reference is retained verbatim: its timestamp participates
 * in the immutable output key. Never reconstruct it from accounting timestamps. */
export function retainedFalReference(value: unknown): JobRef {
  assert(row(value) && Object.keys(value).sort().join(",") === "id,model,poll_url,provider,submitted_at", 503, "The saved video receipt could not be verified.", "upstream");
  assert(value.provider === "fal" && typeof value.model === "string" &&
    typeof value.id === "string" && /^[A-Za-z0-9_-]{1,256}$/.test(value.id) &&
    typeof value.poll_url === "string" && typeof value.submitted_at === "string" &&
    Number.isFinite(Date.parse(value.submitted_at)), 503, "The saved video receipt could not be verified.", "upstream");
  const pair = falLegacyReceipt(value.poll_url, value.poll_url.replace(/\/status$/, ""));
  assert(pair && falLegacyReceiptMatchesModel(value.model, value.id, pair), 503, "The saved video receipt could not be verified.", "upstream");
  return value as unknown as JobRef;
}

export async function retainVideoSubmission(args: { actor: string; org: string; key: string; listing: string; ref: JobRef }, rpc: RPC): Promise<void> {
  const ref = retainedFalReference(args.ref);
  const saved = await rpc("app_video_submission_receipt_save", {
    p_actor: args.actor, p_org: args.org, p_key: args.key, p_listing: args.listing, p_receipt: ref,
  });
  assert(!saved.error && row(saved.data) && saved.data.saved === true,
    503, "The video receipt could not be saved for recovery.", "upstream");
  const echoed = retainedFalReference(saved.data.receipt);
  assert((Object.keys(ref) as (keyof JobRef)[]).every(key => ref[key] === echoed[key]),
    503, "The video receipt could not be saved for recovery.", "upstream");
}

interface Dependencies {
  preferredOrg(req: Request): string | undefined;
  contentOrg(actor: string, preferred: string | undefined, listing: string): Promise<string>;
  rpc: RPC;
  paidReceiptMatches(job: RouterJobToken): Promise<boolean>;
  sign(req: Request, ref: JobRef, owner: { orgId: string; userId: string; listingId: string; admissionKey: string }): Promise<string>;
}

/** Read-only recovery of a lost HTTP202. This never submits, polls a provider,
 * settles accounting, releases a hold or decides that an unknown job is free. */
export async function recoverVideoOperation(req: Request, actor: string, deps: Dependencies): Promise<Response> {
  const params = new URL(req.url).searchParams;
  const key = params.get("operation_id"), listingInput = params.get("listing_id");
  assert(key && UUID.test(key) && listingInput && UUID.test(listingInput), 400, "The saved operation and property are required.");
  const listing = listingInput.toLowerCase(), preferred = deps.preferredOrg(req);
  const org = await deps.contentOrg(actor, preferred, listing);
  const saved = await deps.rpc("app_video_submission_receipt_read", { p_actor: actor, p_org: org, p_key: key, p_listing: listing });
  assert(!saved.error && row(saved.data), 503, "The saved video request could not be checked. Try checking again shortly.", "upstream");
  const data = saved.data;
  assert(data.actor_id === actor && data.org_id === org && data.listing_id === listing && data.operation_id === key,
    503, "The saved video request could not be verified.", "upstream");
  const scope = { operation_id: key, listing_id: listing, selected_library_org_id: preferred ?? null, org_id: org };
  const headers = { "Cache-Control": "private, no-store" };
  if (data.status === "pending") {
    assert(await deps.contentOrg(actor, preferred, listing) === org, 403, "This property is no longer available.");
    return json({ ...scope, status: "pending", message: "This saved request has no confirmed receipt yet. No new video has been started." }, 200, headers);
  }
  assert(data.status === "accepted", 503, "The saved video request could not be verified.", "upstream");
  const ref = retainedFalReference(data.receipt);
  const token: RouterJobToken = { p: ref.provider, m: ref.model, i: ref.id, u: ref.poll_url, t: ref.submitted_at,
    k: "video.reel_clip", o: org, usr: actor, l: listing, a: key, exp: 0 };
  assert(await deps.paidReceiptMatches(token), 403, "This saved video admission no longer matches its receipt.");
  assert(await deps.contentOrg(actor, preferred, listing) === org, 403, "This property is no longer available.");
  const url = await deps.sign(req, ref, { orgId: org, userId: actor, listingId: listing, admissionKey: key });
  assert(await deps.contentOrg(actor, preferred, listing) === org, 403, "This property is no longer available.");
  return json({ ...scope, status: "accepted", request_id: ref.id, status_url: url, response_url: url, kind: "reel", model_id: ref.model }, 200, headers);
}
