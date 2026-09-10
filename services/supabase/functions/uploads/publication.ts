// Pure publication vocabulary. No clients, provider calls, or byte buffering.
import { assert } from "../_shared/http.ts";

export interface FrozenPart { number: number; etag: string }

/** Keep role-bearing basename prefixes and the media extension intact. */
export function publicationKey(ticketKey: string, attempt: string = crypto.randomUUID()): string {
  assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(attempt), 500,
    "Invalid server publication attempt");
  const dot = ticketKey.lastIndexOf(".");
  assert(dot > ticketKey.lastIndexOf("/") && dot < ticketKey.length - 1, 500, "Invalid upload ticket key");
  return `${ticketKey.slice(0, dot)}-complete-${attempt}${ticketKey.slice(dot)}`;
}

/** Exact, bounded manifest; never filter malformed/extra parts into validity. */
export function canonicalParts(value: unknown, total: number): FrozenPart[] {
  assert(Number.isInteger(total) && total >= 1 && total <= 10_000, 409, "Asset has no valid recorded part count");
  assert(Array.isArray(value) && value.length === total, 400, `parts[] must contain each part 1…${total} exactly once`);
  const parts = value.map((part) => {
    assert(part && Number.isInteger(part.number) && part.number >= 1 && part.number <= total &&
      typeof part.etag === "string" && part.etag.trim().length > 0 && part.etag.length <= 256,
    400, `parts[] must contain each part 1…${total} exactly once`);
    // Same quoting normalization as the existing R2 CompleteMultipartUpload.
    const raw = part.etag.trim();
    const etag = raw.startsWith('"') && raw.endsWith('"') ? raw : `"${raw.replace(/^"|"$/g, "")}"`;
    return { number: part.number as number, etag };
  }).sort((a, b) => a.number - b.number);
  assert(parts.every((part, index) => part.number === index + 1), 400,
    `parts[] must contain each part 1…${total} exactly once`);
  return parts;
}

export function sameParts(a: FrozenPart[], b: FrozenPart[]): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}
