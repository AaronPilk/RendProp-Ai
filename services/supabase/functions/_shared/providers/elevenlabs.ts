// ElevenLabs adapter — the shipped voiceover call, wrapped in the interface.
//
//   POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/with-timestamps
//        ?output_format=mp3_44100_128        body { text, model_id? }
//
// The payload is UNCHANGED from ai-voice: `text`, plus `model_id` only when the
// ELEVENLABS_MODEL_ID secret pins one (unset means ElevenLabs' own current
// default, which cannot be retired out from under us the way a hardcoded id can).
// CBR mp3 is deliberate: it makes a duration estimate arithmetic, not a guess.
//
// This is the only vendor in the table that returns PER-CHARACTER alignment, so
// it is the only step `tts.captioned` can route to.

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

const PROVIDER = "elevenlabs";
const ELEVEN_BASE = "https://api.elevenlabs.io";
/** CBR so a duration estimate is arithmetic (mirrors ai-voice). */
export const ELEVEN_OUTPUT_FORMAT = "mp3_44100_128";
export const ELEVEN_OUTPUT_MIME = "audio/mpeg";

function elevenHeaders(): Record<string, string> {
  const key = Deno.env.get("ELEVENLABS_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "ELEVENLABS_API_KEY function secret is not set");
  // `xi-api-key`, never Bearer. Read here and nowhere else.
  return { "xi-api-key": key, "content-type": "application/json" };
}

export interface Alignment {
  characters?: string[];
  character_start_times_seconds?: number[];
  character_end_times_seconds?: number[];
}

/** The shipped body: text, and model_id only when the secret pins one. */
export function elevenPayload(text: string): Record<string, unknown> {
  const payload: Record<string, unknown> = { text };
  const pinned = Deno.env.get("ELEVENLABS_MODEL_ID")?.trim();
  if (pinned) payload.model_id = pinned;
  return payload;
}

export const elevenlabsAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    const voiceId = input.voice_id;
    if (!voiceId) throw new ProviderError(PROVIDER, "validation", "elevenlabs needs a voice_id");
    const text = input.text ?? "";
    if (!text.trim()) throw new ProviderError(PROVIDER, "validation", "elevenlabs needs non-empty text");

    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${ELEVEN_BASE}/v1/text-to-speech/${encodeURIComponent(voiceId)}/with-timestamps` +
        `?output_format=${ELEVEN_OUTPUT_FORMAT}`,
      { method: "POST", headers: elevenHeaders(), body: JSON.stringify(elevenPayload(text)) },
      BUDGETS.submitMs,
    );

    const b64 = data.audio_base64;
    if (typeof b64 !== "string" || b64.length === 0) {
      throw new ProviderError(PROVIDER, "upstream", `ElevenLabs returned no audio: ${snippet(data, 200)}`);
    }
    const id = newJobId("elevenlabs");
    stashInline(id, {
      status: "done",
      result_url: `data:${ELEVEN_OUTPUT_MIME};base64,${b64}`,
      mime: ELEVEN_OUTPUT_MIME,
      meta: {
        // `alignment` indexes the ORIGINAL text; `normalized_alignment` the spoken one.
        alignment: data.alignment ?? null,
        normalized_alignment: data.normalized_alignment ?? null,
        chars: text.length,
        model: step.model,
      },
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
