// content_type.test.ts — the MIME-normalization laundering an audit found
// (P0-2 residual) and its fix.
//
//   deno test services/supabase/functions/uploads/content_type.test.ts
//
// Pure module, no network/DB/Deno.serve — see content_type.ts's header for
// why this lives apart from index.ts.

import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { baseMediaType, isContentTypeDeclared, requireBareContentType } from "./content_type.ts";

// ── requireBareContentType: the CLIENT-declared side (ticket creation) ──────

Deno.test("requireBareContentType: a bare allowed type passes through, lower-cased", () => {
  assertEquals(requireBareContentType("image/jpeg", "content_type"), "image/jpeg");
  assertEquals(requireBareContentType("video/mp4", "content_type"), "video/mp4");
});

Deno.test("requireBareContentType: a parameter is REJECTED, never laundered to the base type", () => {
  // This is the exact audit example: {"content_type":"image/jpeg;evil"} must
  // no longer normalize into an accepted "image/jpeg" ticket.
  const err = assertThrows(() => requireBareContentType("image/jpeg;evil", "content_type"), HttpError);
  assertEquals(err.status, 400);
  assertEquals(err.code, "validation");
  // The error names the field, per the spec ("a 400 naming the field").
  assertEquals(err.message.includes("content_type"), true);
  // And the rejected value is not silently reduced to "image/jpeg" anywhere
  // observable — the whole call throws, nothing is returned.
});

Deno.test("requireBareContentType: the comment's own example — video/mp4;evil — is rejected", () => {
  assertThrows(() => requireBareContentType("video/mp4;evil", "content_type"), HttpError);
});

Deno.test("requireBareContentType: a disallowed-but-well-formed type is a plain string here", () => {
  // requireBareContentType only checks SHAPE, not the allowlist — that's a
  // separate check the caller (validateFileMeta in index.ts) makes against
  // ALLOWED_*_TYPES. A well-formed type/subtype that happens to not be an
  // image/video the route accepts still parses fine at this layer.
  assertEquals(requireBareContentType("text/html", "content_type"), "text/html");
});

Deno.test("requireBareContentType: a value with no slash at all is rejected", () => {
  const err = assertThrows(() => requireBareContentType("evil", "content_type"), HttpError);
  assertEquals(err.status, 400);
});

Deno.test("requireBareContentType: case differences are folded, not rejected (RFC 9110 §8.3.1)", () => {
  assertEquals(requireBareContentType("IMAGE/JPEG", "content_type"), "image/jpeg");
  assertEquals(requireBareContentType("Video/Mp4", "content_type"), "video/mp4");
});

Deno.test("requireBareContentType: leading/trailing whitespace is rejected, not trimmed", () => {
  assertThrows(() => requireBareContentType(" image/jpeg", "content_type"), HttpError);
  assertThrows(() => requireBareContentType("image/jpeg ", "content_type"), HttpError);
  assertThrows(() => requireBareContentType("image/jpeg\t", "content_type"), HttpError);
  assertThrows(() => requireBareContentType("image/jpeg\nimage/png", "content_type"), HttpError);
});

Deno.test("requireBareContentType: internal whitespace (not just a boundary) is rejected", () => {
  assertThrows(() => requireBareContentType("image /jpeg", "content_type"), HttpError);
});

Deno.test("requireBareContentType: the 400 names the ACTUAL field passed in", () => {
  const err = assertThrows(() => requireBareContentType("image/jpeg;x", "files[3].content_type"), HttpError);
  assertEquals(err.message.includes("files[3].content_type"), true);
});

// ── isContentTypeDeclared: absent/blank is "not declared", not "invalid" ────

Deno.test("isContentTypeDeclared: undefined, non-string and blank are all 'not declared'", () => {
  assertEquals(isContentTypeDeclared(undefined), false);
  assertEquals(isContentTypeDeclared(null), false);
  assertEquals(isContentTypeDeclared(42), false);
  assertEquals(isContentTypeDeclared(""), false);
  assertEquals(isContentTypeDeclared("   "), false);
});

Deno.test("isContentTypeDeclared: any non-blank string (even a malformed one) IS a declaration", () => {
  // Declared-but-invalid still routes to requireBareContentType, which is
  // where it gets rejected — isContentTypeDeclared only decides "was
  // something sent", not "is it valid".
  assertEquals(isContentTypeDeclared("image/jpeg"), true);
  assertEquals(isContentTypeDeclared("image/jpeg;evil"), true);
  assertEquals(isContentTypeDeclared(" "), false); // whitespace-only IS blank
});

// ── baseMediaType: the server-OBSERVED side (at /complete) ──────────────────

Deno.test("baseMediaType: a bare type passes through unchanged (lower-cased)", () => {
  assertEquals(baseMediaType("image/jpeg"), "image/jpeg");
  assertEquals(baseMediaType("IMAGE/JPEG"), "image/jpeg");
});

Deno.test("baseMediaType: an observed type with charset= at completion parses to its base", () => {
  // A real HTTP client can legitimately attach a parameter to the Content-Type
  // it PUTs; R2 hands that back verbatim on HEAD. The base type is what /complete
  // checks against the allowlist and the ticket's (already-clean) declared type.
  assertEquals(baseMediaType("image/jpeg; charset=utf-8"), "image/jpeg");
  assertEquals(baseMediaType("video/mp4;codecs=avc1"), "video/mp4");
});

Deno.test("baseMediaType: absent/non-string observed type is the empty string, not a throw", () => {
  assertEquals(baseMediaType(null), "");
  assertEquals(baseMediaType(undefined), "");
  assertEquals(baseMediaType(123), "");
});

Deno.test("baseMediaType: whitespace around the base type is trimmed", () => {
  assertEquals(baseMediaType("  image/jpeg  ; charset=utf-8"), "image/jpeg");
});

// ── End-to-end shape: the declared side can never re-acquire a parameter ────

Deno.test("end-to-end: a declared type, once accepted, is never subject to baseMediaType's laundering", () => {
  // Simulates index.ts's flow: declare -> requireBareContentType -> stored ->
  // later read back and compared via baseMediaType at /complete. A clean
  // declared type round-trips through baseMediaType unchanged (there is
  // nothing to strip), so the /complete equality check stays meaningful.
  const declared = requireBareContentType("image/jpeg", "content_type");
  assertEquals(baseMediaType(declared), declared);
});
