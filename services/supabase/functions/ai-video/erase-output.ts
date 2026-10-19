import { assert, HttpError } from "../_shared/http.ts";

type Job = Record<string, unknown>;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
/** Completed jobs store an object identity, never an expiring download link.
 * The initial job comes from the caller-scoped job RPC; its authority is read
 * again after signing so a withdrawal during this read cannot issue a link. */
export async function renewEraseOutput(job: Job, deps: {
  sign(key: string, expires: number): Promise<string>;
  read(args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
}): Promise<string> {
  const { id, org_id, user_id, output_key } = job;
  assert(job.state === "completed" && [id, org_id, user_id].every(value => typeof value === "string" && UUID.test(value)) &&
    output_key === `video-reflections/${org_id}/${id}.mp4`, 503, "The edited clip could not be verified", "upstream");
  const url = await deps.sign(String(output_key), 600);
  const { data, error } = await deps.read({ p_org: org_id, p_user: user_id, p_job: id });
  const current = data && typeof data === "object" && !Array.isArray(data) ? data as Job : null;
  if (error || !current || current.state !== "completed" || current.id !== id ||
    current.org_id !== org_id || current.user_id !== user_id || current.output_key !== output_key) {
    throw new HttpError(403, "The edited clip is no longer available.");
  }
  assert(typeof url === "string" && url.length > 0, 503, "The edited clip could not be made available", "upstream");
  return url;
}
