// Shared CORS helper for every Edge Function.
// The public tour host (Cloudflare Worker) and the iOS app both call these
// functions cross-origin, so every response must carry these headers and every
// function must answer the OPTIONS preflight.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    // x-region: lets a browser client pin execution to the database's region
    // (Supabase regional invocation) so each DB round trip stays in-region.
    "authorization, x-client-info, apikey, content-type, idempotency-key, x-org-id, x-region",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

/** Standard preflight response. Call at the top of every handler. */
export function handleOptions(): Response {
  return new Response("ok", { status: 200, headers: corsHeaders });
}
