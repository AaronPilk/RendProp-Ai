// content_type.ts — media-type parsing/validation for /uploads.
//
// Pulled out of index.ts (which calls Deno.serve at module load and so is
// never imported by a test — see events/schema.ts or apple-subscriptions/
// logic.ts for the same pattern in this codebase) purely so this logic gets
// direct unit tests instead of only being reachable through an HTTP-level
// integration test. See content_type.test.ts.
//
// ── Audit P0-2 residual: "content-type smuggling through MIME normalization" ─
//
// The old single `mediaType()` helper stripped everything from the first `;`
// onward, trimmed, and lower-cased — and was used BOTH to interpret a
// client-declared `content_type` field AND the server-observed R2 Content-Type
// at /complete. That made `{"content_type":"image/jpeg;evil"}` normalize into
// an accepted "image/jpeg" ticket, exactly the laundering the route's own
// comment claimed could not happen ("video/mp4;evil must not launder into
// video/mp4" — the code did precisely that).
//
// The fix is two DIFFERENT parsers for two DIFFERENT trust levels, never the
// same function doing both jobs:
//
//   • requireBareContentType — a CLIENT-DECLARED content_type (ticket
//     creation: POST /uploads and POST /uploads/batch). RFC 9110 §8.3.1 media
//     types are `type "/" subtype *( OWS ";" OWS parameter )`; the client must
//     send the bare, unparameterized form ONLY. A value carrying a `;`
//     parameter or ANY whitespace is REFUSED with a 400 naming the field —
//     never silently truncated to its base type. So the ticket's declared
//     type — and everything compared against it later — is always the exact,
//     honest value the client sent, never a laundered guess.
//
//   • baseMediaType — the OBSERVED Content-Type on an R2 HEAD (see /complete
//     in index.ts). The presigned PUT URL never binds Content-Type (r2.ts:
//     aws4fetch's signQuery signs only `host`), so this header is whatever the
//     uploader's real HTTP client sent, and — unlike the client's JSON
//     declaration above — there is no request field to refuse: it is a fact
//     about the object, not client input we control the shape of, and a real
//     HTTP client can legitimately suffix it with a parameter (e.g.
//     "; charset=utf-8"). So the parameter is parsed OFF and only the base
//     type is used — checked against the allowlist, and required to match the
//     ticket's (already clean, by construction) declared type EXACTLY. This is
//     not the laundering bug: that was letting the CLIENT'S OWN declaration
//     normalize into an accepted type; this is reading a fact the client does
//     not get to shape at all, and it can only ever narrow what is accepted
//     (an object whose base type isn't allowed, or doesn't match the ticket,
//     is still refused — see index.ts).
//
// Case is folded to lower throughout: RFC 9110 media-type tokens are
// case-insensitive ("IMAGE/JPEG" is the same type as "image/jpeg").

import { HttpError } from "../_shared/http.ts";

// `type "/" subtype`, each 1+ of letters/digits/`.`/`+`/`-`. Every media type
// this route allows (jpeg, png, heic, heif, webp, mp4, quicktime, x-m4v, …)
// fits this; it exists to give a clear 400 on garbage, not to be a complete
// RFC 2045 token grammar — the allowlist right after is the real boundary.
const BARE_MEDIA_TYPE_RE = /^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/;

/**
 * True when `raw` is a declaration worth validating at all. An absent or
 * whitespace-only content_type means "the client didn't declare one" (falls
 * back to a server default) — that is NOT the same thing as "declared an
 * invalid one" (a 400). Only non-empty-after-trim strings go to
 * `requireBareContentType`.
 */
export function isContentTypeDeclared(raw: unknown): raw is string {
  return typeof raw === "string" && raw.trim() !== "";
}

/**
 * Validate a CLIENT-DECLARED content_type: it must be a bare `type/subtype`
 * with NO parameters and NO whitespace anywhere (leading, trailing, or
 * internal — checked on the RAW string, before any trimming). Throws
 * `HttpError(400)` naming `field` when it doesn't qualify; otherwise returns
 * the value lower-cased.
 *
 * Only call this once `isContentTypeDeclared(raw)` is true.
 */
export function requireBareContentType(raw: string, field: string): string {
  if (/[;\s]/.test(raw)) {
    throw new HttpError(
      400,
      `${field} must be a bare type/subtype with no parameters or whitespace (got ${JSON.stringify(raw)})`,
      "validation",
    );
  }
  const lower = raw.toLowerCase();
  if (!BARE_MEDIA_TYPE_RE.test(lower)) {
    throw new HttpError(400, `${field} is not a valid media type (got ${JSON.stringify(raw)})`, "validation");
  }
  return lower;
}

/**
 * Base media type only: everything from the first `;` onward is discarded,
 * then the remainder is trimmed and lower-cased ("" when absent or not a
 * string).
 *
 * ONLY for the server-OBSERVED Content-Type described above. Using this on a
 * client-supplied field is the exact laundering bug this module exists to
 * close — use `requireBareContentType` there instead.
 */
export function baseMediaType(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.split(";")[0].trim().toLowerCase();
}
