// team/codes.ts — invite-code generation, normalisation and hashing.
//
// Pure functions only (no Deno.serve, no env, no network) so codes.test.ts can
// exercise the parts that decide whether a stranger can join somebody's org.
//
// WHY A TYPEABLE CODE AND NOT A LINK. The owner invites an agent who is
// standing in their office, or texts them. A 43-character base64 token is a
// link you must click; a code is something you can read out loud. It is also
// the only form that works before the web /join route exists.
//
// THE ALPHABET omits 0/O/1/I/L/U — the pairs people mistype when reading a code
// off a screen, plus U so no arrangement of the alphabet can spell a word
// somebody has to say out loud to a colleague. 30 symbols over 12 characters is
// 30^12 ≈ 5.3e17, about 59 bits: far past guessing, and the accept route is
// rate-limited and the code expires anyway.

const ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
export const CODE_LENGTH = 12;

/** A fresh invite code, formatted for a human: XXXX-XXXX-XXXX. */
export function generateCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  let raw = "";
  // Rejection-free modulo bias is irrelevant here (256 % 30 = 16 of 256 values
  // are very slightly favoured, costing well under one bit across 12 chars),
  // and the codes are single-use, expiring and rate-limited.
  for (let i = 0; i < CODE_LENGTH; i++) raw += ALPHABET[bytes[i] % ALPHABET.length];
  return format(raw);
}

/** Group into fours with dashes. */
export function format(raw: string): string {
  return (raw.match(/.{1,4}/g) ?? []).join("-");
}

/**
 * The canonical form of whatever the user typed: upper-cased with spaces and
 * dashes removed, then validated character by character against the alphabet.
 *
 * Deliberately does NO character folding. A fold (O->0, I->1) is a second input
 * that hashes to the same code, and the alphabet already excludes every symbol
 * a fold would be for — there is no 0, 1, O, I, L or U in a real code, so a
 * string containing one is a typo we cannot safely guess at, not a near-miss to
 * be repaired.
 *
 * Returns null when the result is not a plausible code. The caller answers the
 * SAME "invalid or expired" for this as for a wrong-but-well-formed code, so it
 * never becomes an oracle telling an attacker their guess had the right shape.
 */
export function normalizeCode(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const s = input.toUpperCase().replace(/[\s-]/g, "");
  if (s.length !== CODE_LENGTH) return null;
  for (const ch of s) if (!ALPHABET.includes(ch)) return null;
  return s;
}

/** sha256 hex of the canonical code. What the database stores. */
export async function hashCode(canonical: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** An e-mail we are willing to store for display. Null when it is not one. */
export function normalizeEmail(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const s = input.trim().toLowerCase();
  if (s.length === 0 || s.length > 254) return null;
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s) ? s : null;
}
