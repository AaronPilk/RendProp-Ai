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
//  • Normal 3.x routes explicitly request imageConfig.imageSize = "1K".
//    Server-prepared, prospectively priced ai-photo edits explicitly request4K;
//    the existing owner comparison retains its separate2K contract.
//    The 3.x image models bill by output resolution and their default is not 1K
//    on every surface — an implicit default is how you silently start paying 4K
//    rates for a 1K product.

import type { RouteStep } from "../router.ts";
import { paramsOf } from "../router.ts";
import { photo2KInputAllowance, photo4KInputAllowance } from "../photo-image-quality.ts";
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
// The legacy GenerateContent hard cutoff includes thoughts and output. The
// serving quote reads the same generation config that is sent to the provider.
export const GEMINI_IMAGE_MAX_OUTPUT_TOKENS = 4096;
//9MB decoded photo =12MB base64, plus bounded JSON/usage/text metadata.
// Applied only to prospective normal4K requests; old provider paths unchanged.
export const GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES=12_100_000;

function geminiKey(): string {
  const key = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "GEMINI_API_KEY function secret is not set");
  return key;
}

/** true for gemini-3.x image models, which must pin output resolution. */
export function needsImageSizePin(model: string): boolean {
  return /^gemini-3(\.|-)/i.test(model.trim());
}

/** Explicitly supported image-edit models; an unknown route fails closed. */
export function supportsStagingReference(model: string): boolean {
  return ["gemini-2.5-flash-image", "gemini-3.1-flash-image", "gemini-3-pro-image-preview"].includes(model.trim());
}

export function geminiImageGenerationConfig(model: string, imageSize: "1K" | "2K" | "4K" = "1K"): Record<string, unknown> {
  if (imageSize !== "1K" && (!["2K","4K"].includes(imageSize) || model !== "gemini-3.1-flash-image"))
    throw new ProviderError(PROVIDER, "validation", "This image model does not support the requested comparison resolution.");
  const generationConfig: Record<string, unknown> = { responseModalities: ["IMAGE"], candidateCount: 1, maxOutputTokens: GEMINI_IMAGE_MAX_OUTPUT_TOKENS };
  // Resolution is explicit; only the verified server route admits higher sizes.
  if (needsImageSizePin(model)) generationConfig.imageConfig = { imageSize };
  return generationConfig;
}

/** The exact generateContent body for an image edit. */
export function geminiImagePayload(model: string, prompt: string, mime: string, imageB64: string,
  reference?: { mime: string; b64: string }, imageSize: "1K" | "2K" | "4K" = "1K"): Record<string, unknown> {
  return {
    contents: [{
      role: "user",
      parts: [
        { text: prompt },
        { inline_data: { mime_type: mime, data: imageB64 } },
        ...(reference ? [
          { text: "FURNITURE REFERENCE ONLY. Edit the first image's room and camera view; use this second image only to match movable furniture. Never copy its architecture, appliances, windows or viewpoint." },
          { inline_data: { mime_type: reference.mime, data: reference.b64 } },
        ] : []),
      ],
    }],
    generationConfig: geminiImageGenerationConfig(model, imageSize),
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
    const referenceB64 = input.extra?.staging_reference_b64;
    let reference: { mime: string; b64: string } | undefined;
    if (referenceB64 !== undefined) {
      if (input.task !== "photo.stage" || !supportsStagingReference(step.model)
        || typeof referenceB64 !== "string" || referenceB64.length === 0 || referenceB64.length > 6_000_000
        || imageB64.length + referenceB64.length > 12_000_000
        || !["image/jpeg", "image/png", "image/webp"].includes(String(input.extra?.staging_reference_mime))) {
        throw new ProviderError(PROVIDER, "validation", "This staging furniture reference is not supported.");
      }
      reference = { mime: String(input.extra?.staging_reference_mime), b64: referenceB64 };
    }

    const requestedSize = paramsOf(step)?.image_size;
    if (input.extra?.photo_quality_4k === true && requestedSize !== "4K")
      throw new ProviderError(PROVIDER, "validation", "The verified 4K photo requires its priced 4K route.");
    if (requestedSize !== undefined && requestedSize !== "1K" && requestedSize !== "2K" && requestedSize !== "4K")
      throw new ProviderError(PROVIDER, "validation", "Unknown image comparison resolution.");
    const imageSize = requestedSize === "4K" ? "4K" : requestedSize === "2K" ? "2K" : "1K";
    if (imageSize === "2K" && photo2KInputAllowance(input) === null)
      throw new ProviderError(PROVIDER, "validation", "The 2K comparison input bound was not verified.");
    if (imageSize === "4K" && photo4KInputAllowance(input) === null)
      throw new ProviderError(PROVIDER, "validation", "The 4K photo input bound was not verified.");
    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${GEMINI_BASE}/${step.model}:generateContent`,
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": geminiKey() },
        body: JSON.stringify(geminiImagePayload(step.model, input.prompt ?? "", mime, imageB64, reference, imageSize)),
      },
      BUDGETS.submitMs,
      classifyGemini,
      input.extra?.photo_quality_4k===true?{maxResponseBytes:GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES}:undefined,
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
