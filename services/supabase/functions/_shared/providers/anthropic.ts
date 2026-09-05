// Anthropic adapter — POST https://api.anthropic.com/v1/messages.
//
//   models  claude-haiku-4-5      (fair-housing OR-gate, QC drift, room labels)
//           claude-sonnet-5       (escalation) — ALWAYS output_config.effort "low"
//   vision  base64 image blocks
//   judge   judge(subject, rubric) -> { flag, reason }
//
// COVERED MODELS NEVER SEE CUSTOMER MEDIA. Any model id containing "fable" or
// "mythos" is refused at construction — not filtered later, not warned about.
// These calls carry photographs of other people's homes, and a Covered Model is
// exactly the wrong place for them. Changing this is a policy decision, not a
// code change.
//
// Sonnet 5 always sends output_config: { effort: "low" }: every call this
// adapter makes is a bounded verdict, and the default effort triples the bill
// for the same answer.

import type { RouteStep } from "../router.ts";
import type { DoneState, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
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

/** Sonnet 5 is always effort:"low"; nothing else carries output_config. */
export function outputConfigFor(model: string): Record<string, unknown> | null {
  return /sonnet-5/i.test(model) ? { effort: "low" } : null;
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
  model: string;
  content: ContentBlock[];
  system?: string;
  maxTokens?: number;
}

/** One bounded /v1/messages call → the concatenated text of the reply. */
export function anthropicClient(model: string) {
  assertNotCoveredModel(model); // construction-time refusal
  return {
    model,
    async messages(args: Omit<MessagesArgs, "model">): Promise<string> {
      return await anthropicMessages({ ...args, model });
    },
    judge(subject: string | ContentBlock[], rubric: string): Promise<JudgeVerdict> {
      return anthropicJudge(model, subject, rubric);
    },
  };
}

export async function anthropicMessages(args: MessagesArgs): Promise<string> {
  assertNotCoveredModel(args.model);
  const body: Record<string, unknown> = {
    model: args.model,
    max_tokens: args.maxTokens ?? 400,
    messages: [{ role: "user", content: args.content }],
  };
  if (args.system) body.system = args.system;
  const outputConfig = outputConfigFor(args.model);
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
  model: string,
  subject: string | ContentBlock[],
  rubric: string,
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
    raw = await anthropicMessages({ model, content, maxTokens: 200 });
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
      model: step.model,
      content,
      system: typeof input.extra?.system === "string" ? input.extra.system : undefined,
      maxTokens: Number(input.extra?.max_tokens) || 400,
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
