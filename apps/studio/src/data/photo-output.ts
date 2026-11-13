// Matches the exact retained supplier output contract. Input editing copies
// and ordinary API metadata keep their smaller, independent bounds.
export const PHOTO_OUTPUT_BYTES = 25 * 1024 * 1024;
export const PHOTO_OUTPUT_BASE64_CHARS = 4 * Math.ceil(PHOTO_OUTPUT_BYTES / 3);
export const PHOTO_OUTPUT_WIRE_BYTES = PHOTO_OUTPUT_BASE64_CHARS + 100_000;

export function photoOutputSize(value: unknown): number | null {
  if (typeof value !== "string" || !value.length || value.length % 4 ||
      value.length > PHOTO_OUTPUT_BASE64_CHARS || /[^A-Za-z0-9+/=]/.test(value)) return null;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  if (value.indexOf("=") !== (padding ? value.length - padding : -1)) return null;
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (padding === 2 && (alphabet.indexOf(value[value.length - 3]!) & 15) !== 0 ||
      padding === 1 && (alphabet.indexOf(value[value.length - 2]!) & 3) !== 0) return null;
  const bytes = value.length / 4 * 3 - padding;
  return bytes > 0 && bytes <= PHOTO_OUTPUT_BYTES ? bytes : null;
}
