// Generation and its later quality check must accept the same prepared source.
// Frames remain small previews; the source can retain the native 2048 px JPEG.
import { HttpError } from "../_shared/http.ts";
import { validatePhotoInput } from "../ai-photo/input-policy.ts";

export const MAX_DRIFT_FRAME_B64_CHARS = 2_000_000;
export const MAX_DRIFT_SOURCE_B64_CHARS = 12_000_000;
// One 12MB base64 source plus three 2MB base64 frames and bounded JSON context.
export const MAX_DRIFT_REQUEST_BODY_BYTES = 19_000_000;
// The existing generic vision bound reserves 2048 tokens/image. A 2048px
// Gemini source can use about 2322; reserve 4096 for the source, independently
// of compression. Anthropic/OpenAI downsampling remains below this bound.
export const DRIFT_SOURCE_EXTRA_INPUT_TOKENS = 2048;

/** Preserve the old small-source contract. Any newly admitted larger source
 * must be a complete still image, <=9MB decoded and <=2048px on either edge.
 * Called before generation admission as well as before its quality check. */
export function validateExtendedReelSource(b64: string, mime: string): void {
  if (b64.length <= MAX_DRIFT_FRAME_B64_CHARS) return;
  const image = validatePhotoInput(b64, mime);
  if (Math.max(image.width, image.height) > 2048) {
    throw new HttpError(413,
      "Use a source no larger than 2048 pixels for video and its quality check.",
      "payload_too_large");
  }
}
