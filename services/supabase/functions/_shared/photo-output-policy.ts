// A supplier's lossless4K PNG can be larger than its9MB editing input.
// Retain the exact supplier bytes within the existing25MiB inline-image bound;
// source admission, pixel geometry and the6MB judge package remain separate.
export const PHOTO_OUTPUT_MAX_BYTES = 25 * 1024 * 1024;
export const PHOTO_OUTPUT_MAX_BASE64_CHARS = 4 * Math.ceil(PHOTO_OUTPUT_MAX_BYTES / 3);
export const PHOTO_OUTPUT_MAX_WIRE_BYTES = PHOTO_OUTPUT_MAX_BASE64_CHARS + 100_000;
