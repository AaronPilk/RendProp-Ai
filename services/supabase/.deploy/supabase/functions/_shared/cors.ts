// Shared CORS helper for every Edge Function.
// The public tour host (Cloudflare Worker) and the iOS app both call these
// functions cross-origin, so every response must carry these headers and every
// function must answer the OPTIONS preflight.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, idempotency-key, x-org-id",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

/** Standard preflight response. Call at the top of every handler. */
export function handleOptions(): Response {
  return new Response("ok", { status: 200, headers: corsHeaders });
}
