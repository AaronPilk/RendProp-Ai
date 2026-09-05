// Gemini adapter — generativelanguage.googleapis.com generateContent.
//
// The request is the SHIPPED one: contents[0].parts = [ {text}, {inline_data} ],
// generationConfig.responseModalities = ["IMAGE"]. Nothing about the 2.5 payload
// changes, which is what keeps `ai_router.enabled = false` a no-op for ai-photo.
//
// TWO deliberate differences from the old hardcoded call:
//
//  • THE MODEL COMES FROM THE ROUTE STEP. gemini-2.5-flash-image retires
//    2026-10-02; the 3.1 migration has to be a row edit in ai_routes, not a
//    deploy. Nothing in this file names a default model.
//  • 3.x models get an EXPLICIT generationConfig.imageConfig.imageSize = "1K".
//    The 3.x image models bill by output resolution and their default is not 1K
//    on every surface — an implicit default is how you silently start paying 4K
//    rates for a 1K product.

import type { RouteStep } from "../router.ts";
import type { DoneState, ErrorClass, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  classifyStatus,
  fetchJson,
  newJobId,
  persistResult,
  snippet,
  stashInline,
  takeInline,
} from "./common.ts";

const PROVIDER = "gemini";
const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

function geminiKey(): string {
  const key = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "GEMINI_API_KEY function secret is not set");
  return key;
}

/** true for gemini-3.x image models, which must be pinned to 1K output. */
export function needsImageSizePin(model: string): boolean {
  return /^gemini-3(\.|-)/i.test(model.trim());
}

/** The exact generateContent body for an image edit. */
export function geminiImagePayload(model: string, prompt: string, mime: string, imageB64: string): Record<string, unknown> {
  const generationConfig: Record<string, unknown> = { responseModalities: ["IMAGE"] };
  // Never pay 4K rates by accident: 3.x is pinned to 1K, explicitly.
  if (needsImageSizePin(model)) generationConfig.imageConfig = { imageSize: "1K" };
  return {
    contents: [{
      role: "user",
      parts: [
        { text: prompt },
        { inline_data: { mime_type: mime, data: imageB64 } },
      ],
    }],
    generationConfig,
  };
}

function classifyGemini(status: number, body: unknown): ErrorClass {
  if (/safety|blocked|prohibited/i.test(snippet(body, 300))) return "nsfw";
  return classifyStatus(status);
}

// deno-lint-ignore no-explicit-any
function firstImage(data: any): { b64: string; mime: string } | null {
  for (const cand of (data?.candidates ?? [])) {
    for (const part of ((cand?.content?.parts) ?? [])) {
      const blob = part.inlineData ?? part.inline_data;
      if (blob?.data) {
        // Gemini's REAL output type — hardcoding image/png mislabelled the bytes
        // the day the image model changed format.
        const m = String(blob.mimeType ?? blob.mime_type ?? "").split(";")[0].trim().toLowerCase();
        return { b64: String(blob.data), mime: m.startsWith("image/") ? m : "image/png" };
      }
    }
  }
  return null;
}

// deno-lint-ignore no-explicit-any
function textParts(data: any): string[] {
  const out: string[] = [];
  for (const cand of (data?.candidates ?? [])) {
    for (const part of ((cand?.content?.parts) ?? [])) {
      if (typeof part?.text === "string" && part.text.trim()) out.push(part.text);
    }
  }
  return out;
}

export const geminiAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    const imageB64 = input.image_b64 ??
      (input.image_url?.startsWith("data:") ? input.image_url.split(",")[1] : undefined);
    if (!imageB64) throw new ProviderError(PROVIDER, "validation", "gemini image edit needs image_b64");
    const mime = String(input.extra?.image_mime ?? "image/jpeg");

    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${GEMINI_BASE}/${step.model}:generateContent`,
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": geminiKey() },
        body: JSON.stringify(geminiImagePayload(step.model, input.prompt ?? "", mime, imageB64)),
      },
      BUDGETS.submitMs,
      classifyGemini,
    );

    const img = firstImage(data);
    const id = newJobId("gemini");
    if (!img) {
      const texts = textParts(data).join(" | ").slice(0, 300);
      // A refusal comes back as text, not as an error status.
      const nsfw = /safety|policy|cannot|refus/i.test(texts);
      stashInline(id, {
        status: "failed",
        error_class: nsfw ? "nsfw" : "upstream",
        message: `Gemini returned no image. ${texts}`,
      });
    } else {
      stashInline(id, {
        status: "done",
        result_url: `data:${img.mime};base64,${img.b64}`,
        mime: img.mime,
        meta: { image_b64: img.b64, model: step.model },
      });
    }
    return { provider: PROVIDER, model: step.model, id, submitted_at: new Date().toISOString() };
  },

  poll(ref: JobRef): Promise<JobState> {
    return Promise.resolve(takeInline(PROVIDER, ref.id));
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
