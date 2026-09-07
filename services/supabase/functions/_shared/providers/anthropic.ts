// Anthropic adapter — POST https://api.anthropic.com/v1/messages.
//
//   models  claude-haiku-4-5      (fair-housing OR-gate, QC drift, room labels)
//           claude-sonnet-5       (escalation) — output_config.effort "low"
//   vision  base64 image blocks
//   judge   judge(subject, rubric) -> { flag, reason }
//
// COVERED MODELS NEVER SEE CUSTOMER MEDIA. Any model id containing "fable" or
// "mythos" is refused at construction — not filtered later, not warned about.
// These calls carry photographs of other people's homes, and a Covered Model is
// exactly the wrong place for them. Changing this is a policy decision, not a
// code change.
//
// Sonnet 5 sends output_config: { effort: "low" } and answers are capped at 400
// tokens: every call this adapter has made so far is a bounded verdict, and the
// default effort triples the bill for the same answer. Both are still the
// DEFAULTS and still what every existing route gets — but they are no longer
// constants keyed off a model-name regex. A route row may carry `params`
// (migration 0030) and outputConfigFor() / anthropicMaxTokens() below
// turn it into the effort and the ceiling for that ONE step, which is what
// keeps "add a model" a row edit instead of a deploy. See _shared/providers/
// params.ts for why the keys are whitelisted rather than passed through.

import type { RouteStep } from "../router.ts";
import { paramsOf } from "../router.ts";
import type { DoneState, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import { paramEnum, paramTokens } from "./params.ts";
import {
  BUDGETS,
  ProviderError,
  fetchJson,
  newJobId,
  persistResult,
  snippet,
  stashInline,
  takeInline,
} from "./common.ts";

const PROVIDER = "anthropic";
const ANTHROPIC_BASE = "https://api.anthropic.com";
const ANTHROPIC_VERSION = "2023-06-01";

/** Model families that must never receive customer media. */
const COVERED_MODEL_MARKERS = ["fable", "mythos"];

/** Throws for a Covered Model. Called at construction AND before every call. */
export function assertNotCoveredModel(model: string): void {
  const m = model.trim().toLowerCase();
  if (COVERED_MODEL_MARKERS.some((marker) => m.includes(marker))) {
    throw new ProviderError(
      PROVIDER,
      "validation",
      `anthropic: "${model}" is a Covered Model — customer media must never be sent to it`,
    );
  }
}

function anthropicKey(): string {
  const key = Deno.env.get("ANTHROPIC_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "ANTHROPIC_API_KEY function secret is not set");
  return key;
}

function anthropicHeaders(): Record<string, string> {
  return {
    "x-api-key": anthropicKey(),
    "anthropic-version": ANTHROPIC_VERSION,
    "content-type": "application/json",
  };
}

/**
 * The efforts /v1/messages accepts in `output_config`. Anthropic has no "none"
 * — the OpenAI-side spelling of "do not think" — so a params blob copied
 * between two steps of the same chain reads as absent here rather than as a
 * body the vendor will 400 on. Absent is always today's behaviour.
 */
export const ANTHROPIC_EFFORTS = ["low", "medium", "high"] as const;
export type AnthropicEffort = typeof ANTHROPIC_EFFORTS[number];

/** The default answer ceiling this adapter shipped with, used whenever neither
 *  a params row nor the caller says otherwise. */
export const ANTHROPIC_DEFAULT_MAX_TOKENS = 400;

/**
 * The `output_config` for one call, or null for "send no output_config at all".
 *
 * WITHOUT PARAMS this is exactly what it always was: Sonnet 5 gets
 * `{ effort: "low" }` and nothing else gets an output_config, keyed off the
 * model name. That regex is the hardcode 0030 exists to make optional, not to
 * delete — the ~70 rows carrying no params must keep behaving byte-for-byte,
 * and today every one of them that reaches this adapter is a bounded verdict
 * where the default effort triples the bill for the same answer.
 *
 * WITH PARAMS the row wins, in both directions: a row may raise a Sonnet step
 * to "medium" for work that deserves it, and a row may put an effort on a model
 * this regex has never heard of — which is the case that used to require a
 * deploy. An unrecognised effort reads as absent and falls back to the regex.
 */
export function outputConfigFor(
  model: string,
  params?: Record<string, unknown> | null,
): Record<string, unknown> | null {
  const effort = paramEnum(params, "effort", ANTHROPIC_EFFORTS);
  if (effort) return { effort };
  return /sonnet-5/i.test(model) ? { effort: "low" } : null;
}

/**
 * The answer ceiling for one call: the row, then the caller, then 400.
 *
 * Same precedence and the same reason as the OpenAI side — the caller's number
 * sizes the visible answer it needs, and the row is what knows a particular
 * model needs more room to produce that same answer. Clamped in params.ts.
 */
export function anthropicMaxTokens(
  params: Record<string, unknown> | null | undefined,
  callerMaxTokens?: number,
): number {
  return paramTokens(params, "max_output_tokens") ?? callerMaxTokens ?? ANTHROPIC_DEFAULT_MAX_TOKENS;
}

/** UTF-8 safe base64 (btoa alone throws on any non-Latin-1 character). */
function utf8ToBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  return btoa(bin);
}

export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } };

/** A base64 image block. The bytes never leave this process except to Anthropic. */
export function imageBlock(b64: string, mime = "image/jpeg"): ContentBlock {
  return { type: "image", source: { type: "base64", media_type: mime, data: b64 } };
}

export interface MessagesArgs {
  /**
   * The ROUTE STEP, or a bare model id.
   *
   * Pass the step wherever you have one — that is the only way a row's `params`
   * reaches the request, and a caller holding the frozen §1 `RouteStep` can
   * pass it as-is (paramsOf() reads the superset column, so no caller needs to
   * know `params` exists). A bare string is the pre-0030 call and gets the
   * pre-0030 body: the model-name effort rule, 400 tokens unless the caller
   * says otherwise.
   */
  model: string | RouteStep;
  content: ContentBlock[];
  system?: string;
  maxTokens?: number;
  /** An explicit params blob, when the caller has one but no step. Wins over
   *  whatever a passed step carries; omit it in every ordinary call. */
  params?: Record<string, unknown> | null;
}

/** One bounded /v1/messages call → the concatenated text of the reply. */
export function anthropicClient(model: string, params?: Record<string, unknown> | null) {
  assertNotCoveredModel(model); // construction-time refusal
  return {
    model,
    async messages(args: Omit<MessagesArgs, "model">): Promise<string> {
      return await anthropicMessages({ params, ...args, model });
    },
    judge(subject: string | ContentBlock[], rubric: string): Promise<JudgeVerdict> {
      return anthropicJudge(model, subject, rubric, params);
    },
  };
}

export async function anthropicMessages(args: MessagesArgs): Promise<string> {
  const model = typeof args.model === "string" ? args.model : args.model.model;
  const params = args.params ?? (typeof args.model === "string" ? null : paramsOf(args.model));
  assertNotCoveredModel(model);
  const body: Record<string, unknown> = {
    model,
    max_tokens: anthropicMaxTokens(params, args.maxTokens),
    messages: [{ role: "user", content: args.content }],
  };
  if (args.system) body.system = args.system;
  const outputConfig = outputConfigFor(model, params);
  if (outputConfig) body.output_config = outputConfig;

  const data = await fetchJson<Record<string, unknown>>(
    PROVIDER,
    `${ANTHROPIC_BASE}/v1/messages`,
    { method: "POST", headers: anthropicHeaders(), body: JSON.stringify(body) },
    BUDGETS.submitMs,
  );
  const content = Array.isArray(data.content) ? data.content : [];
  const text = (content as Array<Record<string, unknown>>)
    .filter((b) => b?.type === "text" && typeof b.text === "string")
    .map((b) => b.text as string)
    .join("")
    .trim();
  if (!text) throw new ProviderError(PROVIDER, "upstream", `Anthropic returned no text: ${snippet(data, 200)}`);
  return text;
}

export interface JudgeVerdict {
  flag: boolean;
  reason: string;
}

/**
 * The classifier behind the fair-housing OR-gate and the QC drift check.
 * `subject` is either text or image blocks (up to four frames for QC).
 *
 * FAILS TOWARD REVIEW: an unparseable or missing verdict is `flag: true`. The
 * gate exists to catch the case where a model says something it should not; a
 * broken judge that silently passes everything is worse than no judge.
 */
export async function anthropicJudge(
  model: string | RouteStep,
  subject: string | ContentBlock[],
  rubric: string,
  params?: Record<string, unknown> | null,
): Promise<JudgeVerdict> {
  const content: ContentBlock[] = typeof subject === "string"
    ? [{ type: "text", text: `${rubric}\n\nSUBJECT:\n${subject}` }]
    : [{ type: "text", text: rubric }, ...subject];
  content.push({
    type: "text",
    text: 'Reply with STRICT JSON only: {"flag":true|false,"reason":"<=120 chars"}',
  });

  let raw: string;
  try {
    raw = await anthropicMessages({ model, content, maxTokens: 200, params });
  } catch (e) {
    if (e instanceof ProviderError && e.error_class === "validation") throw e; // Covered Model
    return { flag: true, reason: `judge unavailable: ${snippet(e instanceof Error ? e.message : e, 80)}` };
  }
  const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    const parsed = JSON.parse(cleaned) as { flag?: unknown; reason?: unknown };
    return { flag: parsed.flag === true, reason: String(parsed.reason ?? "").slice(0, 200) };
  } catch {
    return { flag: true, reason: "judge returned unparseable output" };
  }
}

// ── Adapter ──────────────────────────────────────────────────────────────────

export const anthropicAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    assertNotCoveredModel(step.model);
    const content: ContentBlock[] = [];
    if (input.prompt) content.push({ type: "text", text: input.prompt });
    if (input.image_b64) {
      content.push(imageBlock(input.image_b64, String(input.extra?.image_mime ?? "image/jpeg")));
    }
    const frames = input.extra?.image_b64_frames;
    if (Array.isArray(frames)) {
      for (const f of frames.slice(0, 4)) {
        if (typeof f === "string") content.push(imageBlock(f, String(input.extra?.image_mime ?? "image/jpeg")));
      }
    }
    if (content.length === 0) throw new ProviderError(PROVIDER, "validation", "anthropic needs a prompt or an image");

    const text = await anthropicMessages({
      // The whole step, not step.model: the adapter path always has one, so the
      // row's params reach the request without a caller remembering to.
      model: step,
      content,
      system: typeof input.extra?.system === "string" ? input.extra.system : undefined,
      maxTokens: Number(input.extra?.max_tokens) || ANTHROPIC_DEFAULT_MAX_TOKENS,
    });

    const id = newJobId("anthropic");
    stashInline(id, {
      status: "done",
      result_url: `data:text/plain;base64,${utf8ToBase64(text)}`,
      mime: "text/plain",
      meta: { text },
    });
    return { provider: PROVIDER, model: step.model, id, submitted_at: new Date().toISOString() };
  },

  poll(ref: JobRef): Promise<JobState> {
    return Promise.resolve(takeInline(PROVIDER, ref.id));
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
