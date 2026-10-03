import { assert } from "./http.ts";

/** One caller-selected key per logical paid submission; never invent a key here. */
export function requiredIdempotencyKey(req: Pick<Request, "headers">): string {
  const key = req.headers.get("idempotency-key");
  assert(
    key !== null && /^[\x21-\x7e]{8,128}$/.test(key),
    400,
    "A valid Idempotency-Key of 8 to 128 printable characters is required",
  );
  return key;
}
