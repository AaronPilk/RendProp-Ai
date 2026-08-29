// Cloudflare Stream API helpers — used by account deletion (P0-4) so
// "delete your account" also removes Stream-hosted tour videos, not just rows.
//
// Needs CLOUDFLARE_ACCOUNT_ID + a Stream-scoped API token. When the token env
// is absent the helpers report not-configured instead of pretending success —
// the caller records the UIDs in the deletion tombstone for the sweeper.

const ACCOUNT_ID = Deno.env.get("CLOUDFLARE_ACCOUNT_ID");
const STREAM_TOKEN = Deno.env.get("CLOUDFLARE_STREAM_API_TOKEN") ??
  Deno.env.get("CLOUDFLARE_API_TOKEN");

export function streamConfigured(): boolean {
  return Boolean(ACCOUNT_ID && STREAM_TOKEN);
}

/** Delete one Stream video. Returns true when gone (200 or already absent). */
export async function deleteStreamVideo(uid: string): Promise<boolean> {
  if (!streamConfigured()) throw new Error("Stream API not configured");
  const res = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/stream/${encodeURIComponent(uid)}`,
    { method: "DELETE", headers: { Authorization: `Bearer ${STREAM_TOKEN}` } },
  );
  if (res.ok || res.status === 404) return true;
  const text = await res.text().catch(() => "");
  throw new Error(`Stream DELETE ${uid} -> ${res.status} ${text.slice(0, 200)}`);
}
