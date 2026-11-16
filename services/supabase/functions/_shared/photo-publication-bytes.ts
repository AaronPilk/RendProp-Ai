import { assert, HttpError } from "./http.ts";
import { PHOTO_OUTPUT_MAX_BYTES } from "./photo-output-policy.ts";

export const PHOTO_PUBLICATION_MAX_BYTES = PHOTO_OUTPUT_MAX_BYTES;
export type PublicationObject = {
  key: string;
  bytes: number;
  mime: string;
  etag: string;
  sha256?: string | null;
};
export type PublicationProof = {
  sha256: string;
  bytes: number;
  mime: string;
  etag: string;
};

export function publicationMediaType(bytes: Uint8Array): string | null {
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "image/jpeg";
  if ([137, 80, 78, 71, 13, 10, 26, 10].every((n, i) => bytes[i] === n)) return "image/png";
  if (bytes.length >= 12 && new TextDecoder().decode(bytes.subarray(0, 4)) === "RIFF" &&
    new TextDecoder().decode(bytes.subarray(8, 12)) === "WEBP") return "image/webp";
  return null;
}

export async function publicationHash(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (n) => n.toString(16).padStart(2, "0")).join("");
}

/** Hash the actual bounded response. Upload metadata is only an expectation. */
export async function verifyPublicationBody(
  response: Response,
  expected: PublicationObject,
  signal: AbortSignal,
): Promise<{ proof: PublicationProof; body: Uint8Array<ArrayBuffer> }> {
  assert(Number.isSafeInteger(expected.bytes) && expected.bytes > 0 &&
    expected.bytes <= PHOTO_PUBLICATION_MAX_BYTES &&
    ["image/jpeg", "image/png", "image/webp"].includes(expected.mime) &&
    typeof expected.etag === "string" && expected.etag.length > 0 && expected.etag.length <= 256,
  503, "The saved publication receipt is incomplete.");
  const length = response.headers.get("content-length");
  const mime = (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  const etag = response.headers.get("etag");
  if (!(response.status === 200 && response.body && length !== null && /^\d+$/.test(length) &&
    Number(length) === expected.bytes && mime === expected.mime && etag === expected.etag)) {
    void response.body?.cancel().catch(() => {});
    throw new HttpError(409, "The stored photo changed. Its saved edit and listing selection are kept.");
  }
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      signal.throwIfAborted();
      const item = await new Promise<ReadableStreamReadResult<Uint8Array>>((resolve, reject) => {
        const abort = () => { signal.removeEventListener("abort", abort); reject(signal.reason ?? new DOMException("Aborted", "AbortError")); };
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) { abort(); return; }
        reader.read().then((value) => { signal.removeEventListener("abort", abort); resolve(value); },
          (error) => { signal.removeEventListener("abort", abort); reject(error); });
      });
      signal.throwIfAborted();
      if (item.done) break;
      total += item.value.length;
      assert(total <= expected.bytes && total <= PHOTO_PUBLICATION_MAX_BYTES, 409, "The stored photo exceeds its exact receipt.");
      chunks.push(item.value);
    }
  } finally {
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
  assert(total === expected.bytes, 409, "The saved photo download was incomplete. No substitute was used.");
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
  assert(publicationMediaType(body) === expected.mime, 409, "The stored photo format does not match its receipt.");
  const sha256 = await publicationHash(body);
  if (expected.sha256 !== null && expected.sha256 !== undefined) {
    assert(/^[a-f0-9]{64}$/.test(expected.sha256) && sha256 === expected.sha256,
      409, "The stored photo bytes do not match the accepted edit.");
  }
  return { body, proof: { sha256, bytes: total, mime, etag } };
}
