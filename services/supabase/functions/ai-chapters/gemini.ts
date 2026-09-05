// ai-chapters — the Gemini video-understanding call, isolated from the handler.
//
// SHAPE VERIFIED 2026-09-04 against the live docs (not from memory):
//   https://ai.google.dev/gemini-api/docs/generate-content/video-understanding
//   https://ai.google.dev/gemini-api/docs/generate-content/media-resolution
//   https://ai.google.dev/gemini-api/docs/files
//
// Two things those docs settle, and both of them shape this file:
//
//  1. `file_data.file_uri` accepts FILES API URIs and YouTube URLs. An arbitrary
//     public HTTPS URL is NOT documented as supported — so a presigned R2 URL
//     cannot be handed to the model directly. The object is streamed R2 → Files
//     API instead (resumable protocol), used once, and DELETED immediately.
//     Google auto-expires files after 48 h; that is the backstop, not the plan.
//     This is customer media (`carries_customer_media: true` in the router
//     context), so it does not sit on a third party's disk for two days when one
//     DELETE costs nothing.
//
//  2. `media_resolution` lives in `generation_config` (the per-PART form is
//     `{"media_resolution":{"level":…}}` and is Gemini-3-only). At
//     MEDIA_RESOLUTION_LOW a video frame costs 70 tokens; at 1 fps that is 70
//     tokens per second of walkthrough, which is what makes a house cost ~1¢.
//
// Google is also rolling out a beta `POST /v1beta/interactions` API (typed
// `input` blocks, `response_format`, per-item `"resolution":"low"`). Its own
// documentation says: "For stable production deployments, we recommend you
// continue to use the generateContent API." We use generateContent — which is
// also what ai-photo already speaks, so there is one Gemini dialect in the repo.

import { HttpError } from "../_shared/http.ts";

const GEMINI_BASE = "https://generativelanguage.googleapis.com";
const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY")?.trim() || undefined;

/** 503 when the provider is not configured. Names the SECRET, never its value. */
export function requireGemini(): void {
  if (!GEMINI_KEY) {
    throw new HttpError(
      503,
      "Room-chapter suggestions aren't configured on this server: the GEMINI_API_KEY " +
        "function secret is not set. Set it with services/supabase/set-secrets.sh and redeploy.",
      "upstream",
    );
  }
}

function keyHeader(): Record<string, string> {
  return { "x-goog-api-key": GEMINI_KEY! };
}

/** Never let a provider body reach the client verbatim — it can echo a key. */
function upstream(what: string, status: number, body: string): HttpError {
  console.error(`ai-chapters ${what} failed (${status}): ${body.slice(0, 400)}`);
  return new HttpError(
    502,
    `The video model could not be reached (${what} returned ${status}). Try again in a moment.`,
    "upstream",
  );
}

// ── Files API ────────────────────────────────────────────────────────────────

export interface UploadedFile {
  /** "files/abc123" — the DELETE / GET handle. */
  name: string;
  /** The `file_uri` for `file_data`. */
  uri: string;
  mimeType: string;
  sizeBytes: number | null;
}

interface GeminiFile {
  name?: string;
  uri?: string;
  mimeType?: string;
  sizeBytes?: string | number;
  state?: string;
  error?: { message?: string };
}

/** The Files API wraps its payload in `{ file: … }` on upload but not on GET. */
interface FileEnvelope extends GeminiFile {
  file?: GeminiFile;
}

/**
 * Stream a video from a presigned R2 GET straight into the Files API.
 *
 * NOTHING IS BUFFERED. The R2 response body is handed to the upload fetch as a
 * ReadableStream, so a 200 MB walkthrough costs the edge function a socket, not
 * 200 MB of its 256 MB heap. `duplex: "half"` is required by the fetch spec for
 * a stream body and is not in every TS lib, hence the local widening.
 */
export async function uploadVideoFromUrl(args: {
  sourceUrl: string;
  mimeType: string;
  displayName: string;
  maxBytes: number;
}): Promise<UploadedFile> {
  const src = await fetch(args.sourceUrl);
  if (!src.ok || !src.body) {
    await src.body?.cancel().catch(() => {});
    throw new HttpError(
      502,
      `The walkthrough could not be read from storage (${src.status}).`,
      "upstream",
    );
  }

  const headerLength = Number(src.headers.get("content-length") ?? "");
  const bytes = Number.isFinite(headerLength) && headerLength > 0 ? headerLength : 0;
  if (bytes <= 0) {
    await src.body.cancel().catch(() => {});
    // The resumable protocol wants the length up front; without it the upload
    // would finalize at an unknown size and the model would see a truncated file.
    throw new HttpError(
      409,
      "Storage did not report this video's size, so it can't be sent for analysis. Re-upload the walkthrough and try again.",
      "conflict",
    );
  }
  if (bytes > args.maxBytes) {
    await src.body.cancel().catch(() => {});
    throw new HttpError(
      413,
      `This walkthrough is ${(bytes / 1_000_000).toFixed(0)} MB. Room suggestions accept up to ` +
        `${Math.floor(args.maxBytes / 1_000_000)} MB — publish the rendered tour and run suggestions on that instead.`,
    );
  }

  // 1. start the resumable session (JSON metadata only)
  const start = await fetch(`${GEMINI_BASE}/upload/v1beta/files`, {
    method: "POST",
    headers: {
      ...keyHeader(),
      "content-type": "application/json",
      "x-goog-upload-protocol": "resumable",
      "x-goog-upload-command": "start",
      "x-goog-upload-header-content-length": String(bytes),
      "x-goog-upload-header-content-type": args.mimeType,
    },
    body: JSON.stringify({ file: { display_name: args.displayName } }),
  });
  if (!start.ok) {
    await src.body.cancel().catch(() => {});
    throw upstream("files:start", start.status, await start.text().catch(() => ""));
  }
  const uploadUrl = start.headers.get("x-goog-upload-url");
  await start.body?.cancel().catch(() => {});
  if (!uploadUrl) {
    await src.body.cancel().catch(() => {});
    throw upstream("files:start", start.status, "no x-goog-upload-url header");
  }

  // 2. stream the bytes and finalize in one command
  const init: RequestInit & { duplex?: string } = {
    method: "POST",
    headers: {
      "content-type": args.mimeType,
      "x-goog-upload-offset": "0",
      "x-goog-upload-command": "upload, finalize",
    },
    body: src.body,
    duplex: "half",
  };
  const put = await fetch(uploadUrl, init);
  const putText = await put.text().catch(() => "");
  if (!put.ok) throw upstream("files:upload", put.status, putText);

  let env: FileEnvelope;
  try {
    env = JSON.parse(putText) as FileEnvelope;
  } catch {
    throw upstream("files:upload", put.status, "unparseable JSON");
  }
  const file = env.file ?? env;
  const name = typeof file.name === "string" ? file.name : "";
  const uri = typeof file.uri === "string" ? file.uri : "";
  if (!name || !uri) throw upstream("files:upload", put.status, "no file name/uri in response");

  const size = Number(file.sizeBytes ?? bytes);
  return {
    name,
    uri,
    mimeType: typeof file.mimeType === "string" ? file.mimeType : args.mimeType,
    sizeBytes: Number.isFinite(size) ? size : bytes,
  };
}

/**
 * Poll until the Files API finishes transcoding. A video is PROCESSING for a few
 * seconds after upload and generateContent 400s on a non-ACTIVE file, so this is
 * not optional. Bounded by `deadlineMs` — an edge function has a wall clock.
 */
export async function waitForActive(name: string, deadlineMs: number): Promise<void> {
  const path = name.startsWith("files/") ? name : `files/${name}`;
  let delay = 900;
  while (Date.now() < deadlineMs) {
    const res = await fetch(`${GEMINI_BASE}/v1beta/${path}`, { headers: keyHeader() });
    const text = await res.text().catch(() => "");
    if (!res.ok) throw upstream("files:get", res.status, text);
    let env: FileEnvelope;
    try {
      env = JSON.parse(text) as FileEnvelope;
    } catch {
      throw upstream("files:get", res.status, "unparseable JSON");
    }
    const file = env.file ?? env;
    const state = String(file.state ?? "").toUpperCase();
    if (state === "ACTIVE") return;
    if (state === "FAILED") {
      throw new HttpError(
        502,
        `The video model could not decode this walkthrough${file.error?.message ? ` (${file.error.message})` : ""}. ` +
          `Re-encode it as H.264 mp4 and try again.`,
        "upstream",
      );
    }
    await new Promise((r) => setTimeout(r, delay));
    delay = Math.min(3000, Math.round(delay * 1.5));
  }
  throw new HttpError(
    504,
    "The video model is still preparing this walkthrough. Try room suggestions again in a minute.",
    "upstream",
  );
}

/** Best effort. Customer media does not linger on a third party for 48 hours. */
export async function deleteFile(name: string): Promise<void> {
  try {
    const path = name.startsWith("files/") ? name : `files/${name}`;
    const res = await fetch(`${GEMINI_BASE}/v1beta/${path}`, {
      method: "DELETE",
      headers: keyHeader(),
    });
    await res.body?.cancel().catch(() => {});
    if (!res.ok) console.error(`ai-chapters files:delete returned ${res.status} for ${path}`);
  } catch (e) {
    console.error("ai-chapters files:delete threw:", e instanceof Error ? e.message : String(e));
  }
}

// ── generateContent ──────────────────────────────────────────────────────────

/**
 * The strict JSON schema. `response_schema` uses the OpenAPI subset Gemini
 * documents (UPPERCASE type names); `property_ordering` makes the model emit the
 * fields in the order a human would write them, which measurably steadies the
 * timestamps.
 */
export const CHAPTER_SCHEMA = {
  type: "OBJECT",
  properties: {
    chapters: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          label: { type: "STRING", description: "The room or area name, from the allowed list." },
          start_s: { type: "NUMBER", description: "Seconds from the start of the video when this room is first entered." },
          end_s: { type: "NUMBER", description: "Seconds from the start of the video when the camera leaves this room." },
          confidence: { type: "NUMBER", description: "0 to 1. How sure you are of this room label." },
          description: { type: "STRING", description: "One sentence about the SPACE ITSELF: finishes, light, layout." },
        },
        required: ["label", "start_s", "end_s"],
        property_ordering: ["label", "start_s", "end_s", "confidence", "description"],
      },
    },
    summary: { type: "STRING", description: "One or two sentences describing the property's layout." },
    warnings: { type: "ARRAY", items: { type: "STRING" } },
  },
  required: ["chapters"],
  property_ordering: ["chapters", "summary", "warnings"],
} as const;

export interface GenerateArgs {
  model: string;
  fileUri: string;
  mimeType: string;
  systemInstruction: string;
  prompt: string;
  /** Frames per second the model samples. 1 fps is the documented default. */
  fps: number;
  maxOutputTokens?: number;
}

export interface GenerateResult {
  /** The model's raw JSON text (already `application/json` by response_mime_type). */
  text: string;
  promptTokens: number | null;
  outputTokens: number | null;
  finishReason: string | null;
}

/** Build the EXACT request body we POST. Exported so a test can assert its shape. */
export function buildGenerateBody(args: GenerateArgs): Record<string, unknown> {
  return {
    system_instruction: { parts: [{ text: args.systemInstruction }] },
    contents: [
      {
        role: "user",
        parts: [
          {
            file_data: { mime_type: args.mimeType, file_uri: args.fileUri },
            video_metadata: { fps: args.fps },
          },
          { text: args.prompt },
        ],
      },
    ],
    generation_config: {
      media_resolution: "MEDIA_RESOLUTION_LOW",
      response_mime_type: "application/json",
      response_schema: CHAPTER_SCHEMA,
      temperature: 0.2,
      candidate_count: 1,
      max_output_tokens: args.maxOutputTokens ?? 4096,
    },
  };
}

/** One `:generateContent` call. Returns the first text part, verbatim. */
export async function generateChapters(args: GenerateArgs): Promise<GenerateResult> {
  const url = `${GEMINI_BASE}/v1beta/models/${encodeURIComponent(args.model)}:generateContent`;
  const res = await fetch(url, {
    method: "POST",
    headers: { ...keyHeader(), "content-type": "application/json" },
    body: JSON.stringify(buildGenerateBody(args)),
  });
  const text = await res.text().catch(() => "");
  if (!res.ok) throw upstream("generateContent", res.status, text);

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    throw upstream("generateContent", res.status, "unparseable JSON");
  }

  const candidate = body?.candidates?.[0];
  const finishReason = typeof candidate?.finishReason === "string" ? candidate.finishReason : null;
  if (!candidate && body?.promptFeedback?.blockReason) {
    throw new HttpError(
      502,
      "The video model declined to analyse this walkthrough. Tag the rooms by hand for this one.",
      "upstream",
    );
  }
  const parts: Array<{ text?: string }> = candidate?.content?.parts ?? [];
  const out = parts.map((p) => (typeof p?.text === "string" ? p.text : "")).join("").trim();

  const usage = body?.usageMetadata ?? {};
  const num = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : null);
  return {
    text: out,
    promptTokens: num(usage.promptTokenCount),
    outputTokens: num(usage.candidatesTokenCount),
    finishReason,
  };
}
