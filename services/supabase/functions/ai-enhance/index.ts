// ai-enhance — THIN validate + enqueue endpoint (202).
//
//   POST /ai-enhance  { job_id, feature:"declutter"|"restage"|"hero",
//                       image_key | frames, style?, mask_key? } -> 202 { queued }
//
// TODO: provider calls (Flux/Nano Banana/Seedance + Claude QC) are handled by
// services/pipeline; this endpoint ONLY validates, runs a pre-flight cost-cap
// check, and enqueues the request onto the render job. The pipeline consumes
// render_jobs.enhancements._requests, makes the metered provider calls, and
// records real spend via _shared/ledger.logCost(). The eventual synchronous
// contract (BACKEND-ARCHITECTURE §2) returns { output_key, cost_cents, qc_score }.
//
// Auth: the render worker calls with the service-role key; the app calls with a
// user JWT and must be a member of the job's org.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, isServiceRole } from "../_shared/supabase.ts";
import { ESTIMATED_UNIT_COST_CENTS, jobSpentCents, MAX_GEN_COST_PER_JOB_CENTS } from "../_shared/ledger.ts";

const FEATURES = ["declutter", "restage", "hero"];

interface EnhanceBody {
  job_id: string;
  feature: string;
  image_key?: string;
  frames?: string[];
  style?: string;
  mask_key?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "POST") throw new HttpError(405, "Only POST is supported");
    const body = await readJson<EnhanceBody>(req);

    assert(body.job_id, 400, "job_id is required");
    assert(FEATURES.includes(body.feature), 400, `feature must be one of ${FEATURES.join(", ")}`);
    const hasFrames = Array.isArray(body.frames) && body.frames.length > 0;
    assert(body.image_key || hasFrames, 400, "image_key or frames is required");

    const admin = adminClient();

    // Load the job + its org (via the listing).
    const { data: job, error: jErr } = await admin
      .from("render_jobs")
      .select("id, listing_id, status, enhancements, cost_cents")
      .eq("id", body.job_id)
      .maybeSingle();
    if (jErr) throw new HttpError(500, `Job lookup failed: ${jErr.message}`);
    if (!job) throw new HttpError(404, "Render job not found");

    const { data: listing } = await admin
      .from("listings")
      .select("org_id")
      .eq("id", job.listing_id)
      .maybeSingle();
    const orgId = listing?.org_id ?? null;

    // AuthZ: service-role worker OR an org member.
    if (!isServiceRole(req)) {
      const user = await getUser(req);
      if (orgId) {
        const { data: member } = await admin
          .from("memberships")
          .select("id")
          .eq("user_id", user.id)
          .eq("org_id", orgId)
          .maybeSingle();
        if (!member) throw new HttpError(403, "Not a member of this job's org");
      } else {
        throw new HttpError(403, "Job has no org");
      }
    }

    // Pre-flight cost cap: reject before queuing if this would blow the budget.
    const spent = await jobSpentCents(admin, job.id);
    const estUnit = ESTIMATED_UNIT_COST_CENTS[body.feature] ?? 0;
    if (spent + estUnit > MAX_GEN_COST_PER_JOB_CENTS) {
      throw new HttpError(
        402,
        `Cost cap reached: job ${job.id} at ${spent}¢, +${estUnit}¢ would exceed ` +
          `MAX_GEN_COST_PER_JOB_CENTS=${MAX_GEN_COST_PER_JOB_CENTS}¢`,
      );
    }

    // Enqueue onto the job. enhancements._requests is an additive queue the
    // pipeline polls; the product-facing keys ({declutter, style}) are untouched.
    const requestId = crypto.randomUUID();
    const enh = (job.enhancements as Record<string, unknown>) ?? {};
    const requests = Array.isArray(enh._requests) ? (enh._requests as unknown[]) : [];
    requests.push({
      id: requestId,
      feature: body.feature,
      image_key: body.image_key ?? null,
      frames: hasFrames ? body.frames : null,
      style: body.style ?? null,
      mask_key: body.mask_key ?? null,
      status: "queued",
      queued_at: new Date().toISOString(),
    });

    const patch: Record<string, unknown> = {
      enhancements: { ...enh, _requests: requests },
      current_step: `enqueue:${body.feature}`,
    };
    if (job.status === "created") patch.status = "queued";

    const { error: upErr } = await admin.from("render_jobs").update(patch).eq("id", job.id);
    if (upErr) throw new HttpError(500, `Enqueue failed: ${upErr.message}`);

    return json(
      {
        ok: true,
        status: "queued",
        job_id: job.id,
        request_id: requestId,
        feature: body.feature,
        estimated_cost_cents: estUnit,
      },
      202,
    );
  } catch (err) {
    return respondError(err);
  }
});
