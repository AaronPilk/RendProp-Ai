import { assert, HttpError } from "../_shared/http.ts";
import { entitlementFor } from "../_shared/entitlements.ts";
import { recordRoutedAiCost } from "../_shared/ledger.ts";
import { resolveRoute, orderSteps, paramsOf, reportOutcome, type ChainStep, type RouteStep } from "../_shared/router.ts";
import { errorClassOf } from "../_shared/providers/common.ts";
import { assertNotCoveredModel, outputConfigFor } from "../_shared/providers/anthropic.ts";
import { openaiChatConfig } from "../_shared/providers/openai.ts";
import { EDIT_PLAN_LIMITS, EDIT_PLAN_TASK, type EditPlanDependencies } from "./edit-plan.ts";
import type { StudioContext } from "./context.ts";

const MAX_PROVIDER_BYTES = 64 * 1024;
/** A single bounded text request. Reuses adapter model configuration rules, with
 * a smaller hard ceiling. The generic adapter buffers the entire response, so
 * this endpoint reads its tiny text-only response through a bounded reader.
 * No SDK retries, chain failover, model tools, media blocks or arbitrary URLs. */
export async function generateEditPlanText(step: RouteStep, system: string, turn: string, fetcher: typeof fetch = fetch): Promise<string> {
  const params = { ...paramsOf(step), max_output_tokens: EDIT_PLAN_LIMITS.tokens };
  let url: string, headers: Record<string, string>, body: Record<string, unknown>;
  if (step.provider === "anthropic") {
    assertNotCoveredModel(step.model);
    const key = Deno.env.get("ANTHROPIC_API_KEY")?.trim();
    assert(key, 503, "The editing service is not configured.");
    url = "https://api.anthropic.com/v1/messages";
    headers = { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" };
    body = { model: step.model, max_tokens: EDIT_PLAN_LIMITS.tokens, system, messages: [{ role: "user", content: [{ type: "text", text: turn }] }] };
    const output = outputConfigFor(step.model, params); if (output) body.output_config = output;
  } else {
    assert(step.provider === "openai", 503, "The editing service is not configured.");
    const key = Deno.env.get("OPENAI_API_KEY")?.trim();
    assert(key, 503, "The editing service is not configured.");
    const config = openaiChatConfig(params, EDIT_PLAN_LIMITS.tokens);
    url = "https://api.openai.com/v1/responses";
    headers = { "content-type": "application/json", authorization: `Bearer ${key}` };
    body = { model: step.model, store: false, max_output_tokens: config.maxOutputTokens, reasoning: { effort: config.effort }, text: { format: { type: "json_object" } },
      input: [{ role: "developer", content: [{ type: "input_text", text: system }] }, { role: "user", content: [{ type: "input_text", text: turn }] }] };
  }
  let response: Response;
  try { response = await fetcher(url, { method: "POST", headers, body: JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(30_000) }); }
  catch { throw new HttpError(502, "The editing request did not finish. No automatic retry was started."); }
  if (!response.ok) { await response.body?.cancel(); throw new HttpError(502, "The editing service could not return an edit. No automatic retry was started."); }
  if (Number(response.headers.get("content-length")) > MAX_PROVIDER_BYTES) { await response.body?.cancel(); throw new HttpError(502, "The editing service returned too much data."); }
  const reader = response.body?.getReader(); assert(reader, 502, "The editing service returned no answer.");
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) {
      const next = await reader.read(); if (next.done) break;
      size += next.value.length;
      assert(size <= MAX_PROVIDER_BYTES, 502, "The editing service returned too much data."); chunks.push(next.value);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let data: Record<string, unknown>;
  try { data = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new HttpError(502, "The editing service returned an unreadable answer."); }
  assert(data && typeof data === "object" && !Array.isArray(data), 502, "The editing service returned an unreadable answer.");
  let result = "";
  if (step.provider === "anthropic") {
    assert(data.stop_reason === "end_turn" && Array.isArray(data.content), 502, "The editing service did not finish its answer.");
    result = (data.content as Record<string, unknown>[]).filter(part => part?.type === "text" && typeof part.text === "string").map(part => part.text).join("");
  } else {
    assert(data.status === "completed" && data.error == null && data.incomplete_details == null, 502, "The editing service did not finish its answer.");
    if (typeof data.output_text === "string") result = data.output_text;
    else if (Array.isArray(data.output)) result = data.output.flatMap(item => Array.isArray(item?.content) ? item.content : []).filter(part => part?.type === "output_text" && typeof part.text === "string").map(part => part.text).join("");
  }
  assert(!!result.trim() && new TextEncoder().encode(result).byteLength <= EDIT_PLAN_LIMITS.responseBytes, 502, "The editing service returned no usable answer.");
  return result;
}

export function editPlanProduction(context: StudioContext, task: "copy.edit_plan" | "copy.prompt_enhancement" = EDIT_PLAN_TASK): EditPlanDependencies {
  const { admin, userId, orgId } = context;
  const limit = () => Number(Deno.env.get("STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS") ?? "0");
  const enabled = () => Deno.env.get("STUDIO_EDIT_PLANNER_ENABLED") === "true" && Number.isFinite(limit()) && limit() > 0 && limit() <= 10;
  return {
    enabled,
    async writable() {
      const results = await Promise.all([
        admin.from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle(),
        admin.from("orgs").select("id").eq("id", orgId).is("deleted_at", null).maybeSingle(),
        admin.from("deletion_requests").select("user_id").eq("user_id", userId).neq("status", "completed").limit(1),
      ]);
      assert(results.every(result => !result.error), 503, "Workspace access could not be checked.");
      return !!results[1].data && !(results[2].data?.length) && ["owner", "admin", "agent"].includes(results[0].data?.role ?? "");
    },
    async route() {
      if (!enabled()) return null;
      // No fallback constants or legacy task: an explicit active task row must
      // exist. Normal router capability/plan/privacy/retirement ordering applies.
      const entitlement = await entitlementFor(orgId); if (entitlement.degraded) return null;
      const routing = { plan: entitlement.plan, needs: ["text", "compliant"] };
      // Legacy resolution normally skips plan/retirement eligibility. Reapply
      // the shared pure filters so this new task cannot inherit that exception.
      const steps = orderSteps(await resolveRoute(task, routing) as ChainStep[], routing, new Map());
      const step = steps.find(candidate => candidate.enabled && candidate.task === task && ["openai", "anthropic"].includes(candidate.provider) && candidate.unit === "call" && Number.isFinite(candidate.unit_cents) && candidate.unit_cents > 0 && candidate.unit_cents <= limit() &&
        !!Deno.env.get(candidate.provider === "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY")?.trim());
      if (!step) return null;
      if (step.provider === "anthropic") { try { assertNotCoveredModel(step.model); } catch { return null; } }
      // resolveRoute's legacy path may degrade through unavailable rows. This
      // endpoint never accepts that degradation as an enablement decision.
      const active = await admin.from("ai_routes").select("id").eq("id", step.route_id).eq("task", task).eq("enabled", true).maybeSingle();
      if (active.error || !active.data) return null;
      return step;
    },
    async reserve(requestId) {
      const bump = async (key: string, max: number, seconds: number) => {
        const result = await admin.rpc("bump_rate", { p_key: key, p_window_seconds: seconds, p_max: max, p_cost: 1 });
        assert(!result.error, 503, "Editing request limits could not be checked."); return result.data === true;
      };
      assert(await bump(`edit-plan:user:${userId}`, 12, 300), 429, "Please wait before asking for another AI edit.");
      assert(await bump(`edit-plan:day:${userId}`, 60, 86400), 429, "Today's AI editing request limit has been reached.");
      assert(await bump(`edit-plan:org:${orgId}`, 60, 300), 429, "This workspace has several edits in progress. Please wait.");
      // Retry suppression, not replayable-result storage: an uncertain POST is
      // never replayed or failed over. UUIDs are scoped to both actor and org.
      assert(await bump(`edit-plan:request:${orgId}:${userId}:${requestId}`, 1, 86400), 409, "This request was already submitted. Your current edit is preserved; send a new message only if you want a separate attempt.");
    },
    async generate(step, system, turn) {
      const started = Date.now();
      try {
        const result = await generateEditPlanText(step, system, turn);
        await reportOutcome(step, { ok: true, latency_ms: Date.now() - started });
        return result;
      } catch (error) {
        await reportOutcome(step, { ok: false, latency_ms: Date.now() - started, error_class: errorClassOf(error) });
        throw error;
      }
    },
    async record(step, outcome) {
      await recordRoutedAiCost(admin, { orgId, feature: "copy_assist", step, meta: { kind: task === EDIT_PLAN_TASK ? "edit_plan" : "prompt_enhancement", attempts: 1, outcome, price_estimated: true } });
    },
    async spaceType(listingId) {
      if (!listingId) return null;
      const result = await context.db.from("listings").select("space_type").eq("id", listingId).eq("org_id", orgId).is("deleted_at", null).maybeSingle();
      assert(!result.error && result.data, 403, "This property is unavailable.");
      return result.data.space_type ?? null;
    },
  };
}
