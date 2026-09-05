// OpenAI adapter — images/edits, TTS, transcription, and chat.
//
//   POST /v1/images/edits          gpt-image-2, multipart, optional mask
//   POST /v1/audio/speech          tts-1
//   POST /v1/audio/transcriptions  whisper-1 + timestamp_granularities[]=word
//   POST /v1/responses             any chat/vision call
//
// Four vendor facts encoded here, each of which has cost somebody a day:
//
//  • gpt-image-2 REJECTS `input_fidelity`. It is a gpt-image-1 parameter. It is
//    never sent from this file — do not add it back for "better fidelity".
//  • /v1/audio/speech (tts-1) returns AUDIO ONLY. There are no word timings, so
//    the tts route this adapter serves must NEVER advertise the "timestamps"
//    capability — captions come from ElevenLabs with-timestamps or from whisper.
//  • whisper-1 gives word timings only with BOTH response_format=verbose_json
//    and timestamp_granularities[]=word. Ask for one without the other and you
//    silently get segment timings.
//  • every chat call sends reasoning: { effort: "none" }. These are one-shot
//    classifier and captioning calls; reasoning tokens on them are pure cost.
//
// Everything here answers inside the submit call, so submit() stashes the
// finished state and poll() hands it back once (see common.ts stashInline).

import type { RouteStep } from "../router.ts";
import type { DoneState, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  b64Bytes,
  bytesToB64,
  fetchBounded,
  fetchJson,
  newJobId,
  persistResult,
  snippet,
  stashInline,
  takeInline,
} from "./common.ts";

const PROVIDER = "openai";
const OPENAI_BASE = "https://api.openai.com";

function openaiKey(): string {
  const key = Deno.env.get("OPENAI_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "OPENAI_API_KEY function secret is not set");
  return key;
}

function authHeader(): Record<string, string> {
  return { "Authorization": `Bearer ${openaiKey()}` };
}

/** gpt-image sizes. 16:9 and 9:16 have no exact size — these are the supported
 *  landscape/portrait canvases and the closest thing the API offers. */
export function imageSizeFor(aspect: string | undefined): string {
  switch (aspect) {
    case "16:9":
      return "1536x1024";
    case "9:16":
      return "1024x1536";
    case "1:1":
      return "1024x1024";
    default:
      return "auto";
  }
}

/** Source bytes for an edit: inline base64 preferred, else a bounded download. */
async function sourceBlob(input: GenerateInput, field: "image" | "mask"): Promise<Blob | null> {
  const b64 = field === "image" ? input.image_b64 : undefined;
  const url = field === "image" ? input.image_url : input.mask_url;
  const mime = String(input.extra?.[field === "image" ? "image_mime" : "mask_mime"] ?? "image/png");
  if (b64) return new Blob([b64Bytes(b64)], { type: mime });
  if (url?.startsWith("data:")) {
    const [, payload] = url.split(",", 2);
    return new Blob([b64Bytes(payload ?? "")], { type: mime });
  }
  if (url && /^https:\/\//i.test(url)) {
    const res = await fetchBounded(PROVIDER, url, { method: "GET" }, BUDGETS.transferMs);
    if (!res.ok) throw new ProviderError(PROVIDER, "upstream", `Could not read the source ${field} (HTTP ${res.status})`);
    const buf = await res.arrayBuffer();
    return new Blob([buf], { type: res.headers.get("content-type") ?? mime });
  }
  return null;
}

// ── Whisper ──────────────────────────────────────────────────────────────────

export interface TimedWord {
  text: string;
  start: number;
  end: number;
}

/** verbose_json + timestamp_granularities[]=word → the caption timeline. */
export function mapWhisperWords(payload: unknown): TimedWord[] {
  const words = (payload as { words?: unknown })?.words;
  if (!Array.isArray(words)) return [];
  const out: TimedWord[] = [];
  for (const raw of words) {
    if (!raw || typeof raw !== "object") continue;
    const o = raw as Record<string, unknown>;
    const text = String(o.word ?? o.text ?? "").trim();
    const start = Number(o.start);
    const end = Number(o.end);
    if (!text || !Number.isFinite(start) || !Number.isFinite(end)) continue;
    out.push({ text, start, end });
  }
  return out;
}

// ── Chat ─────────────────────────────────────────────────────────────────────

export interface JudgeVerdict {
  flag: boolean;
  reason: string;
}

/**
 * One bounded chat call. `reasoning: { effort: "none" }` on EVERY call — the
 * router only ever sends this model one-shot classifier work.
 */
export async function openaiChat(
  model: string,
  input: unknown,
  opts: { maxOutputTokens?: number; json?: boolean } = {},
): Promise<string> {
  const body: Record<string, unknown> = {
    model,
    input,
    reasoning: { effort: "none" },
    max_output_tokens: opts.maxOutputTokens ?? 300,
  };
  if (opts.json) body.text = { format: { type: "json_object" } };
  const data = await fetchJson<Record<string, unknown>>(
    PROVIDER,
    `${OPENAI_BASE}/v1/responses`,
    { method: "POST", headers: { ...authHeader(), "Content-Type": "application/json" }, body: JSON.stringify(body) },
    BUDGETS.submitMs,
  );
  if (typeof data.output_text === "string" && data.output_text.trim()) return data.output_text;
  const output = Array.isArray(data.output) ? data.output : [];
  for (const item of output as Array<Record<string, unknown>>) {
    const content = Array.isArray(item?.content) ? item.content : [];
    for (const part of content as Array<Record<string, unknown>>) {
      if (typeof part?.text === "string" && part.text.trim()) return part.text;
    }
  }
  throw new ProviderError(PROVIDER, "upstream", `OpenAI returned no text: ${snippet(data, 200)}`);
}

/** The OpenAI half of the fair-housing OR-gate (flag if EITHER judge flags). */
export async function openaiJudge(model: string, subject: string, rubric: string): Promise<JudgeVerdict> {
  const raw = await openaiChat(
    model,
    [{
      role: "user",
      content: [{
        type: "input_text",
        text: `${rubric}\n\nReply with strict JSON: {"flag":true|false,"reason":"<=120 chars"}\n\nSUBJECT:\n${subject}`,
      }],
    }],
    { json: true, maxOutputTokens: 200 },
  );
  try {
    const parsed = JSON.parse(raw) as { flag?: unknown; reason?: unknown };
    return { flag: parsed.flag === true, reason: String(parsed.reason ?? "").slice(0, 200) };
  } catch {
    // An unparseable judge is not a pass: the OR-gate must fail toward review.
    return { flag: true, reason: "judge returned unparseable output" };
  }
}

// ── Adapter ──────────────────────────────────────────────────────────────────

export const openaiAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    const id = newJobId("openai");
    const model = step.model;
    let state: JobState;

    if (step.task.startsWith("stt.")) {
      // whisper-1 word timings.
      const audio = input.extra?.audio;
      if (!(audio instanceof Blob)) {
        throw new ProviderError(PROVIDER, "validation", "transcription needs extra.audio (a Blob)");
      }
      const form = new FormData();
      form.set("file", audio, String(input.extra?.filename ?? "audio.mp3"));
      form.set("model", model);
      form.set("response_format", "verbose_json");
      form.append("timestamp_granularities[]", "word");
      const data = await fetchJson<Record<string, unknown>>(
        PROVIDER,
        `${OPENAI_BASE}/v1/audio/transcriptions`,
        { method: "POST", headers: authHeader(), body: form },
        BUDGETS.submitMs,
      );
      const words = mapWhisperWords(data);
      const json = JSON.stringify({ text: data.text ?? "", words });
      state = {
        status: "done",
        result_url: `data:application/json;base64,${bytesToB64(new TextEncoder().encode(json))}`,
        mime: "application/json",
        duration_s: Number(data.duration) || undefined,
        meta: { text: String(data.text ?? ""), words },
      };
    } else if (step.task.startsWith("tts.")) {
      // tts-1: audio only, NO timestamps (the route must not claim them).
      const res = await fetchBounded(
        PROVIDER,
        `${OPENAI_BASE}/v1/audio/speech`,
        {
          method: "POST",
          headers: { ...authHeader(), "Content-Type": "application/json" },
          body: JSON.stringify({
            model,
            input: input.text ?? "",
            voice: input.voice_id ?? "alloy",
            response_format: "mp3",
          }),
        },
        BUDGETS.submitMs,
      );
      if (!res.ok) {
        const detail = await res.text().catch(() => "");
        throw new ProviderError(PROVIDER, "upstream", `openai HTTP ${res.status}: ${snippet(detail)}`, res.status);
      }
      const bytes = new Uint8Array(await res.arrayBuffer());
      state = {
        status: "done",
        result_url: `data:audio/mpeg;base64,${bytesToB64(bytes)}`,
        mime: "audio/mpeg",
        meta: { chars: (input.text ?? "").length },
      };
    } else {
      // gpt-image-2 edit. Multipart; mask optional; quality medium; NEVER
      // input_fidelity (gpt-image-2 rejects it).
      const image = await sourceBlob(input, "image");
      if (!image) throw new ProviderError(PROVIDER, "validation", "an image edit needs image_b64 or image_url");
      const form = new FormData();
      form.set("model", model);
      form.set("image", image, "source.png");
      const mask = await sourceBlob(input, "mask");
      if (mask) form.set("mask", mask, "mask.png");
      form.set("prompt", input.prompt ?? "");
      form.set("size", imageSizeFor(input.aspect));
      form.set("quality", "medium");

      const data = await fetchJson<Record<string, unknown>>(
        PROVIDER,
        `${OPENAI_BASE}/v1/images/edits`,
        { method: "POST", headers: authHeader(), body: form },
        BUDGETS.submitMs,
      );
      const first = Array.isArray(data.data) ? (data.data[0] as Record<string, unknown>) : null;
      const b64 = typeof first?.b64_json === "string" ? first.b64_json : null;
      if (!b64) throw new ProviderError(PROVIDER, "upstream", `OpenAI returned no image: ${snippet(data, 200)}`);
      state = {
        status: "done",
        result_url: `data:image/png;base64,${b64}`,
        mime: "image/png",
        meta: { image_b64: b64, size: imageSizeFor(input.aspect), quality: "medium" },
      };
    }

    stashInline(id, state);
    return { provider: PROVIDER, model, id, submitted_at: new Date().toISOString() };
  },

  poll(ref: JobRef): Promise<JobState> {
    return Promise.resolve(takeInline(PROVIDER, ref.id));
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
